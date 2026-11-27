"""Give verified GaoJiLing MSIs private identities for installer smoke tests."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import uuid
import warnings
from pathlib import Path

with warnings.catch_warnings():
    warnings.simplefilter("ignore", DeprecationWarning)
    import msilib

from package_msi import UPGRADE_CODE


def guid(value: uuid.UUID) -> str:
    return "{" + str(value).upper() + "}"


def read_rows(database, query: str, width: int) -> list[tuple[str, ...]]:
    view = database.OpenView(query)
    try:
        view.Execute(None)
        rows = []
        while record := view.Fetch():
            rows.append(tuple(record.GetString(index) for index in range(1, width + 1)))
        return rows
    finally:
        view.Close()


def execute(database, query: str) -> None:
    view = database.OpenView(query)
    try:
        view.Execute(None)
    finally:
        view.Close()


def verified_release(source: Path) -> tuple[tuple[int, ...], str]:
    source = source.resolve(strict=True)
    expected = source.with_name(source.name + ".sha256").read_text(encoding="ascii").split()[0]
    with source.open("rb") as handle:
        actual = hashlib.file_digest(handle, "sha256").hexdigest()
    if actual != expected.lower():
        raise ValueError("MSI SHA-256 did not match")
    database = msilib.OpenDatabase(str(source), msilib.MSIDBOPEN_READONLY)
    properties = dict(read_rows(database, "SELECT `Property`, `Value` FROM `Property`", 2))
    upgrades = read_rows(database, "SELECT `UpgradeCode` FROM `Upgrade`", 1)
    if properties.get("ProductName") != "GaoJiLing" or properties.get("UpgradeCode") != guid(UPGRADE_CODE):
        raise ValueError("Unexpected MSI product or upgrade family")
    if not upgrades or any(code != guid(UPGRADE_CODE) for (code,) in upgrades):
        raise ValueError("MSI can target an unrelated upgrade family")
    version = properties.get("ProductVersion", "")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("Unexpected MSI product version")
    return tuple(map(int, version.split("."))), actual


def isolated_copy(
    source: Path,
    destination: Path,
    release: tuple[tuple[int, ...], str],
    family: str,
    components: dict[str, str],
) -> dict[str, str]:
    version, checksum = release
    with source.open("rb") as original, destination.open("xb") as copy:
        shutil.copyfileobj(original, copy)
    with destination.open("rb") as copy:
        if hashlib.file_digest(copy, "sha256").hexdigest() != checksum:
            raise ValueError("Source MSI changed while preparing its private copy")
    database = msilib.OpenDatabase(str(destination), msilib.MSIDBOPEN_TRANSACT)
    product = guid(uuid.uuid4())
    execute(database, f"UPDATE `Property` SET `Value` = '{product}' WHERE `Property` = 'ProductCode'")
    execute(database, f"UPDATE `Property` SET `Value` = '{family}' WHERE `Property` = 'UpgradeCode'")
    execute(database, "UPDATE `Property` SET `Value` = 'GaoJiLing installer smoke' WHERE `Property` = 'ProductName'")
    upgrade_rows = read_rows(
        database,
        "SELECT `VersionMin`, `VersionMax`, `Language`, `Attributes`, `Remove`, `ActionProperty` FROM `Upgrade`",
        6,
    )
    execute(database, "DELETE FROM `Upgrade`")
    msilib.add_data(database, "Upgrade", [
        (family, lower or None, upper or None, language or None, int(attributes), remove or None, action)
        for lower, upper, language, attributes, remove, action in upgrade_rows
    ])
    for (component,) in read_rows(database, "SELECT `ComponentId` FROM `Component`", 1):
        canonical = guid(uuid.UUID(component))
        if component != canonical:
            raise ValueError("Unexpected MSI component identity")
        replacement = components.setdefault(canonical, guid(uuid.uuid4()))
        execute(database, f"UPDATE `Component` SET `ComponentId` = '{replacement}' WHERE `ComponentId` = '{canonical}'")
    execute(database, "UPDATE `Component` SET `Condition` = '0' WHERE `Component` = 'Registration'")
    summary = database.GetSummaryInformation(1)
    package_code = guid(uuid.uuid4())
    summary.SetProperty(msilib.PID_REVNUMBER, package_code)
    summary.Persist()
    database.Commit()
    del summary, database
    database = msilib.OpenDatabase(str(destination), msilib.MSIDBOPEN_READONLY)
    properties = dict(read_rows(database, "SELECT `Property`, `Value` FROM `Property`", 2))
    registrations = read_rows(database, "SELECT `Condition` FROM `Component` WHERE `Component` = 'Registration'", 1)
    fixture_families = {code for (code,) in read_rows(database, "SELECT `UpgradeCode` FROM `Upgrade`", 1)}
    component_codes = {code for (code,) in read_rows(database, "SELECT `ComponentId` FROM `Component`", 1)}
    if (properties.get("ProductCode") != product or properties.get("UpgradeCode") != family
            or fixture_families != {family} or registrations != [("0",)]
            or not component_codes <= set(components.values())
            or database.GetSummaryInformation(0).GetProperty(msilib.PID_REVNUMBER) != package_code.encode("ascii")):
        raise ValueError("MSI isolation could not be verified")
    return {"path": str(destination), "product": product, "version": f"{version[0]}.{version[1]}+{version[2]}"}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workspace", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--previous", type=Path)
    args = parser.parse_args()
    candidate_release = verified_release(args.candidate)
    previous_release = verified_release(args.previous) if args.previous else None
    if previous_release is not None and previous_release[0] >= candidate_release[0]:
        raise ValueError("The previous MSI must be older than the candidate")
    family = guid(uuid.uuid4())
    components: dict[str, str] = {}
    workspace = args.workspace.resolve(strict=True)
    candidate = isolated_copy(args.candidate, workspace / "candidate.msi", candidate_release, family, components)
    previous = (
        isolated_copy(args.previous, workspace / "previous.msi", previous_release, family, components)
        if previous_release is not None else None
    )
    print(json.dumps({"candidate": candidate, "previous": previous}))


if __name__ == "__main__":
    main()
