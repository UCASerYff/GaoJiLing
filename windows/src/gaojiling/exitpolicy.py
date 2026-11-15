"""自动退出的纯策略。默认关闭。只在身份、保存状态和观察时长都满足时才允许请求正常退出。"""

from __future__ import annotations

PROTECTED_WORDS = [
    "chrome", "chromium", "firefox", "safari", "brave", "opera", "vivaldi", "arc", "edge", "browser",
    "code", "cursor", "zed", "jetbrains", "sublime", "textmate", "bbedit", "editor", "office", "word", "excel",
    "powerpoint", "adobe", "affinity", "obsidian", "notion", "download", "transmission", "torrent", "folx", "aria2",
    "1password", "bitwarden", "keepass", "security", "antivirus", "littlesnitch", "lulu", "clash", "surge", "vpn",
    "terminal", "iterm", "warp", "docker", "parallels", "vmware", "sync", "dropbox", "onedrive", "backup",
]


def protection_reason(bundle_id: str, path: str, name: str = "", category: str | None = None,
                      url_schemes: list[str] | None = None, document_based: bool = False) -> str | None:
    identifier = bundle_id.lower()
    lower_path = path.lower()
    if identifier in {"com.apple", "com.gaoseries"} or identifier.startswith(("com.apple.", "com.gaoseries.")) or \
            lower_path.startswith(("/system/", "/usr/", "/library/", "c:\\windows\\", "c:\\program files\\")):
        return "系统或搞系列应用始终受保护"
    context = identifier + " " + name.lower()
    if any(word in context for word in PROTECTED_WORDS):
        return "浏览器、编辑器、下载器或系统安全/后台任务应用保守排除"
    if any((scheme or "").lower() in {"http", "https"} for scheme in url_schemes or []):
        return "声明可处理网页的应用可能包含浏览或下载任务，保守排除"
    if document_based:
        return "文稿应用可能保存工作内容，保守排除"
    if category in {"public.app-category.developer-tools", "public.app-category.productivity", "public.app-category.finance",
                    "public.app-category.graphics-design", "public.app-category.video"}:
        return "此应用类别可能保存工作或运行长期任务，保守排除"
    return None


def rule_valid(rule: dict, windows: bool = False) -> bool:
    path = rule.get("path") or ""
    parts = path.replace("\\", "/").split("/")
    suffix_ok = path.lower().endswith(".exe") if windows else path.endswith(".app")
    minutes = rule.get("minutes")
    cooldown = rule.get("cooldownSeconds")
    memory = rule.get("memoryBytes")
    try:
        minutes_ok = minutes == minutes and 1 <= float(minutes) <= 1440
        cooldown_ok = cooldown == cooldown and 60 <= float(cooldown) <= 86400
        memory_ok = 16_777_216 <= int(memory) <= 137_438_953_472
    except (TypeError, ValueError):
        return False
    bundle = rule.get("bundleID") or ""
    name = rule.get("name") or ""
    absolute = path.startswith("/") or (windows and len(path) > 2 and path[1] == ":")
    return bool(bundle) and len(bundle) <= 256 and absolute and suffix_ok and ".." not in parts and len(name) <= 256 and minutes_ok and cooldown_ok and memory_ok


class ExitPolicy:
    def __init__(self):
        self.background_since = {}
        self.last_attempt = {}
        self.last_observation = None

    def reset(self):
        self.background_since.clear()
        self.last_observation = None

    def record_attempt(self, rule_id, when: float):
        self.last_attempt[rule_id] = when

    def restore_cooldowns(self, records: list[dict]):
        for record in records:
            current = self.last_attempt.get(record["ruleID"], -1e100)
            self.last_attempt[record["ruleID"]] = max(current, record["date"])

    def observe(self, observations: list[dict], now: float):
        if self.last_observation is not None and (now - self.last_observation > 30 or now < self.last_observation):
            self.reset()
        self.last_observation = now
        present = {item["identity"] for item in observations}
        self.background_since = {key: value for key, value in self.background_since.items() if key in present}
        for item in observations:
            identity = item["identity"]
            if item["isFrontmost"]:
                self.background_since.pop(identity, None)
            elif identity not in self.background_since:
                self.background_since[identity] = now

    def evaluate(self, rule: dict, observation: dict, now: float, current_uid: int, enabled: bool, paused: bool, windows: bool = False) -> dict:
        def skip(reason):
            return {"eligible": False, "reason": reason}

        if not enabled or not rule.get("enabled"):
            return skip("规则未主动启用")
        if paused:
            return skip("用户暂停或睡眠保护")
        if not rule_valid(rule, windows):
            return skip("规则无效")
        identity = observation["identity"]
        if observation.get("bundleID") != rule.get("bundleID") or observation.get("path") != rule.get("path"):
            return skip("应用身份不匹配")
        if identity[2] != current_uid or identity[0] <= 1 or identity[1] <= 0:
            return skip("应用身份不匹配")
        if not 0 <= now - observation["observedAt"] <= 12:
            return skip("应用观测已过期")
        reason = protection_reason(rule.get("bundleID", ""), rule.get("path", ""), rule.get("name", ""))
        if reason:
            return skip(reason)
        if observation.get("isFrontmost"):
            return skip("前台应用受保护")
        if observation.get("saveState") != "clean":
            return skip("存在未保存内容，已跳过" if observation.get("saveState") == "edited" else "无法确认保存状态，已跳过")
        attempt = self.last_attempt.get(rule["id"])
        if attempt is not None and now - attempt < rule["cooldownSeconds"]:
            return skip("处于冷却期，不重复请求退出")
        start = self.background_since.get(identity)
        if start is None or now - start < rule["minutes"] * 60:
            return skip("等待完整的后台观察时长；不会累计休眠时间")
        trigger = rule.get("trigger")
        if trigger == "用户空闲且后台":
            idle = observation.get("idleSeconds")
            if idle is None or idle != idle or idle < rule["minutes"] * 60:
                return skip("用户空闲时间不足或不可用")
        elif trigger == "无窗口且后台":
            if observation.get("windowCount") != 0:
                return skip("仍有窗口或窗口状态未知")
        elif trigger == "内存超阈值且后台":
            memory = observation.get("memoryBytes")
            if memory is None or memory < rule["memoryBytes"]:
                return skip("应用内存未超阈值或不可用")
        elif trigger != "后台时长":
            return skip("规则无效")
        return {"eligible": True, "reason": f"{trigger}满足规则，保存状态可确认；仅请求正常退出"}
