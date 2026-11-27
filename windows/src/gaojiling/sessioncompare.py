"""Bounded comparison data for saved tasks. No additional sampler is started."""

from __future__ import annotations

DETAIL_LIMIT = 48
POINT_LIMIT = 120
PROCESS_LIMIT = 8
MIN_BUCKET = 10
BACKUP_PREFIX = "GaoJiLing.Windows.SessionCompare."
_MAX_BYTES = (1 << 63) - 1
_NAME_LIMIT = 64


def _number(value, minimum=0, maximum=float("inf")):
    return value if type(value) in (int, float) and minimum <= value <= maximum and value < float("inf") else None


def _memory(value):
    return value if type(value) is int and 0 <= value <= _MAX_BYTES else None


def bucket_seconds(elapsed):
    width = MIN_BUCKET
    while elapsed >= width * POINT_LIMIT:
        width *= 2
    return width


def plot_point(elapsed, cpu, memory):
    return [round(elapsed, 4), None if cpu is None else round(cpu, 3), memory]


def new_detail():
    return {"sampleCount": 0, "memorySampleCount": 0, "bucket": MIN_BUCKET, "points": []}


def _process_rows(sample, moment):
    rows = []
    for process in sample.get("processes") or []:
        cpu = _number(process.get("cpuPercent"), maximum=100)
        name = process.get("name")
        if (cpu is None or process.get("cpuAvailable") is False or process.get("observedAt") != moment
                or not isinstance(name, str) or not name.strip()):
            continue
        memory = None if process.get("memoryAvailabilityReason") else _memory(process.get("memoryBytes"))
        count = len(process.get("pids") or []) or None
        rows.append((name[:_NAME_LIMIT], cpu, memory, count))
    rows.sort(key=lambda row: (-row[1], -(row[2] or 0), row[0].casefold()))
    return [[name, round(cpu, 3), memory, count] for name, cpu, memory, count in rows[:PROCESS_LIMIT]]


def observe(detail, start, sample, previous):
    """Called only for increasing in-session timestamps, using the existing acquisition."""
    moment = sample["timestamp"]
    elapsed = moment - start
    cpu = _number(sample.get("cpuPercent"), maximum=100)
    memory = _memory(sample.get("memoryUsed"))
    if cpu is not None or memory is not None:
        point = plot_point(elapsed, cpu, memory)
        detail.setdefault("first", point[0])
        detail["last"] = point[0]
        detail["sampleCount"] += 1
        if memory is not None:
            detail["memorySampleCount"] += 1
        width = bucket_seconds(point[0])
        points = detail["points"]
        if width != detail["bucket"]:
            points = list({int(row[0] // width): row for row in points}.values())
            detail["points"] = points
            detail["bucket"] = width
        if points and int(points[-1][0] // width) == int(point[0] // width):
            points[-1] = point
        else:
            points.append(point)

    # The first observation can have a CPU baseline from before task start.
    current = detail.get("process")
    baseline = sample.get("processBaselineAt", previous)
    if previous is not None and baseline is not None and baseline >= start and 0 < moment - baseline <= 15 and cpu is not None:
        if current is None or cpu > current[1]:
            rows = _process_rows(sample, moment)
            if rows:
                detail["process"] = [round(elapsed, 4), round(cpu, 3), rows]
    return cpu, memory


def validate_detail(detail, duration):
    """Check imported or stored optional details before exposing them."""
    def valid_offset(value):
        # Elapsed values are stored at 0.1 ms precision.
        return _number(value, maximum=duration + 0.0001) is not None

    def valid_count(value, maximum):
        return type(value) is int and 0 <= value <= maximum

    if (not isinstance(detail, dict)
            or not set(detail) <= {"sampleCount", "memorySampleCount", "bucket", "points", "first", "last", "process"}):
        return False
    count, memory_count = detail.get("sampleCount"), detail.get("memorySampleCount")
    if not valid_count(count, 2**31 - 1) or not valid_count(memory_count, count):
        return False
    points, width = detail.get("points"), detail.get("bucket")
    if (type(width) is not int or not isinstance(points, list) or len(points) > min(count, POINT_LIMIT)
            or bool(count) != bool(points)):
        return False
    first, last = detail.get("first"), detail.get("last")
    if points:
        if not valid_offset(first) or not valid_offset(last) or first > last or width != bucket_seconds(last):
            return False
    elif width != MIN_BUCKET or first is not None or last is not None:
        return False
    previous_bucket = -1
    for point in points:
        if not isinstance(point, list) or len(point) != 3:
            return False
        elapsed, cpu, memory = point
        if (not valid_offset(elapsed) or not first <= elapsed <= last
                or (cpu is not None and _number(cpu, maximum=100) is None)
                or (memory is not None and _memory(memory) is None) or (cpu is None and memory is None)):
            return False
        current_bucket = int(elapsed // width)
        if current_bucket <= previous_bucket:
            return False
        previous_bucket = current_bucket
    process = detail.get("process")
    if process is not None:
        if not isinstance(process, list) or len(process) != 3 or not points:
            return False
        elapsed, cpu, rows = process
        if (not valid_offset(elapsed) or not first <= elapsed <= last or _number(cpu, maximum=100) is None
                or not isinstance(rows, list) or not 1 <= len(rows) <= PROCESS_LIMIT):
            return False
        for row in rows:
            if not isinstance(row, list) or len(row) != 4:
                return False
            name, cpu, working_set, count = row
            if (not isinstance(name, str) or not name.strip() or len(name) > _NAME_LIMIT
                    or _number(cpu, maximum=100) is None
                    or (working_set is not None and _memory(working_set) is None)
                    or (count is not None and not valid_count(count, 2**31 - 1))):
                return False
    return True


def public_run(session, detail, history):
    start, end = session["start"], session["end"]
    duration = max(0.0, end - start)
    count = session["sampleCount"]
    average = _number(session["cpuTotal"] / count, maximum=100) if count else None
    peak = _number(session["peakCPU"], maximum=100) if count else None
    memory = _memory(session["peakMemory"])
    last_observed = session.get("lastObserved")
    if detail is not None:
        source = "session"
        width = detail["bucket"]
        points = detail["points"]
        first, last = detail.get("first"), detail.get("last")
        total_count, memory_count = detail["sampleCount"], detail["memorySampleCount"]
        if not memory_count:
            memory = None
        missing_trend = "这次任务没有保存可用的系统 CPU 或内存采样。"
        missing_processes = "这次任务没有取得完整的会话内进程 CPU 基线和可排名读数。"
        process = detail.get("process")
    else:
        source = "history"
        upper = min(end, last_observed) if last_observed is not None else end
        width = bucket_seconds(max(0.0, upper - start))
        points = []
        for sample in history(start, upper, width) if upper >= start else ():
            cpu = _number(sample.get("cpuPercent"), maximum=100)
            used = _memory(sample.get("memoryUsed"))
            if cpu is not None or used is not None:
                points.append(plot_point(sample["timestamp"] - start, cpu, used))
        first, last = (points[0][0], points[-1][0]) if points else (None, None)
        memory = memory or None  # Legacy zero also represented an unread memory counter.
        total_count, memory_count, process = None, None, None
        missing_trend = "所选时段内没有仍保留的系统历史采样。"
        missing_processes = "这条记录没有归属到本次会话的进程排行。"

    processes = {"available": bool(process), "reason": None if process else missing_processes,
                 "sampledAt": None, "systemCpuPercent": None, "rows": []}
    if process:
        elapsed, system_cpu, rows = process
        processes.update(sampledAt=min(end, start + elapsed), systemCpuPercent=system_cpu, rows=[
            {"name": name, "cpuPercent": cpu, "memoryBytes": working_set, "processCount": row_count}
            for name, cpu, working_set, row_count in rows
        ])
    return {"id": session["id"], "name": session["name"], "start": start, "end": end,
            "interrupted": bool(session.get("interrupted")), "durationSeconds": duration,
            "cpuAveragePercent": average, "cpuPeakPercent": peak, "memoryPeakBytes": memory,
            "sampleCount": total_count, "cpuSampleCount": count, "memorySampleCount": memory_count,
            "sampleStart": min(end, start + first) if first is not None else None,
            "sampleEnd": min(end, start + last) if last is not None else None,
            "trend": {"available": bool(points), "reason": None if points else missing_trend, "source": source,
                      "bucketSeconds": width, "gapSeconds": max(15, width * 1.5, 65 if source == "history" else 0),
                      "points": [{"elapsedSeconds": elapsed, "cpuPercent": cpu, "memoryBytes": used}
                                 for elapsed, cpu, used in points]}, "processes": processes}


def public_compare(runs):
    return {"sessions": runs, "comparable": {
        "durationSeconds": all(not row["interrupted"] for row in runs),
        **{key: all(row[key] is not None for row in runs)
           for key in ("cpuAveragePercent", "cpuPeakPercent", "memoryPeakBytes")},
        "processes": all(row["processes"]["available"] for row in runs),
    }}
