import json
import os
import threading
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import gi
gi.require_version('GLib', '2.0')
from gi.repository import GLib

@dataclass
class UsageData:
    session_percent: float
    session_reset_in: str
    session_active: bool
    weekly_percent: float
    weekly_resets_at: str
    weekly_active: bool
    daily_routines: int
    daily_routines_max: int
    usage_credits: bool
    last_updated: str

    @classmethod
    def placeholder(cls):
        return cls(
            session_percent=0.0, session_reset_in="—", session_active=False,
            weekly_percent=0.0, weekly_resets_at="—", weekly_active=False,
            daily_routines=0, daily_routines_max=5,
            usage_credits=False, last_updated="never"
        )

    @classmethod
    def mock(cls):
        return cls(
            session_percent=61.0, session_reset_in="2h 8m", session_active=True,
            weekly_percent=14.0, weekly_resets_at="Sat 9:00 AM", weekly_active=True,
            daily_routines=0, daily_routines_max=5,
            usage_credits=False, last_updated="mock data"
        )

    @property
    def emoji(self) -> str:
        if self.session_percent >= 86: return "🔴"
        if self.session_percent >= 61: return "🟠"
        return "🟢"

    @property
    def tray_title(self) -> str:
        if not self.session_active: return "○ No session"
        pct = int(round(self.session_percent))
        return f"{self.emoji} {pct}% · {self.session_reset_in}"


class UsageManager:
    ENDPOINT = "https://api.anthropic.com/api/oauth/usage"

    def __init__(self):
        self.usage = UsageData.placeholder()
        self.is_loading = False
        self.error_message = None
        self.token_missing = False
        self.token_expired = False
        
        self.on_update = None          # callback(title: str)
        self.on_state_change = None    # callback() — triggers UI redraw
        
        self._poll_timer_id = None
        self._countdown_timer_id = None
        
        self._last_fetch: datetime | None = None
        self._session_resets_at: datetime | None = None
        self._weekly_resets_at: datetime | None = None

    @property
    def _status_title(self) -> str:
        if self.token_missing: return "○ Sign in"
        if self.token_expired: return "⚠ Expired"
        return self.usage.tray_title

    def start(self):
        self.fetch_async()
        self._poll_timer_id = GLib.timeout_add_seconds(120, self._poll_tick)
        self._countdown_timer_id = GLib.timeout_add_seconds(60, self._countdown_tick)

    def stop(self):
        if self._poll_timer_id:
            GLib.source_remove(self._poll_timer_id)
            self._poll_timer_id = None
        if self._countdown_timer_id:
            GLib.source_remove(self._countdown_timer_id)
            self._countdown_timer_id = None

    def _poll_tick(self) -> bool:
        self.fetch_async()
        return True

    def _countdown_tick(self) -> bool:
        self._refresh_countdown()
        return True

    def _refresh_countdown(self):
        if not self._last_fetch:
            return
            
        if self._session_resets_at:
            self.usage.session_reset_in = self.relative_until(self._session_resets_at)
        if self._weekly_resets_at:
            self.usage.weekly_resets_at = self.absolute_reset(self._weekly_resets_at)
            
        if self._last_fetch:
            self.usage.last_updated = self.relative_since(self._last_fetch)
            
        if self.on_update:
            self.on_update(self._status_title)
        if self.on_state_change:
            self.on_state_change()

    # Launch at login
    @staticmethod
    def get_launch_at_login() -> bool:
        return UsageManager._autostart_desktop_file().exists()

    def set_launch_at_login(self, enabled: bool):
        file = UsageManager._autostart_desktop_file()
        if enabled:
            file.parent.mkdir(parents=True, exist_ok=True)
            content = (
                "[Desktop Entry]\n"
                "Type=Application\n"
                "Name=Claude Usage Bar\n"
                "Exec=claude-usage-bar\n"
                "Icon=claude-usage-bar\n"
                "X-GNOME-Autostart-enabled=true\n"
            )
            file.write_text(content)
        else:
            file.unlink(missing_ok=True)
            
        if self.on_state_change:
            self.on_state_change()

    @staticmethod
    def _autostart_desktop_file() -> Path:
        return Path.home() / ".config" / "autostart" / "claude-usage-bar.desktop"

    # Fetching
    def fetch_async(self):
        if self.is_loading:
            return
        self.is_loading = True
        threading.Thread(target=self._fetch_thread, daemon=True).start()

    def _fetch_thread(self):
        def publish_results(token_missing, token_expired, error_message, raw_data, last_fetch):
            self.token_missing = token_missing
            self.token_expired = token_expired
            self.error_message = error_message
            if raw_data:
                self._session_resets_at = self.parse_date(raw_data.get("five_hour", {}).get("resets_at"))
                self._weekly_resets_at = self.parse_date(raw_data.get("seven_day", {}).get("resets_at"))
                self.usage = self._map(raw_data)
                self._last_fetch = last_fetch
                if self._last_fetch:
                    self.usage.last_updated = self.relative_since(self._last_fetch)
            
            self.is_loading = False
            
            if self.on_update:
                self.on_update(self._status_title)
            if self.on_state_change:
                self.on_state_change()
            return False

        try:
            token = self._read_oauth_token()
            if not token:
                if self._credentials_exist():
                    GLib.idle_add(publish_results, False, True, None, None, None)
                else:
                    GLib.idle_add(publish_results, True, False, None, None, None)
                return

            req = urllib.request.Request(self.ENDPOINT)
            req.add_header("Authorization", f"Bearer {token}")
            req.add_header("Content-Type", "application/json")
            req.add_header("anthropic-beta", "oauth-2025-04-20")
            req.add_header("User-Agent", "ClaudeUsageBar-Linux/1.0")

            with urllib.request.urlopen(req) as response:
                data = response.read()
                raw = json.loads(data)
                
            GLib.idle_add(publish_results, False, False, None, raw, datetime.now(timezone.utc))
            
        except urllib.error.HTTPError as e:
            if e.code == 429:
                GLib.idle_add(publish_results, False, False, "Rate limited — will retry automatically", None, None)
            elif e.code == 401:
                GLib.idle_add(publish_results, False, True, None, None, None)
            else:
                GLib.idle_add(publish_results, False, False, f"API error {e.code}", None, None)
        except Exception as e:
            GLib.idle_add(publish_results, False, False, str(e), None, None)

    # Mapping
    @staticmethod
    def _map(raw: dict) -> UsageData:
        five_hour = raw.get("five_hour", {})
        seven_day = raw.get("seven_day", {})
        extra = raw.get("extra_usage", {})
        
        five_hour_resets = UsageManager.parse_date(five_hour.get("resets_at"))
        seven_day_resets = UsageManager.parse_date(seven_day.get("resets_at"))
        
        session_active = (five_hour_resets.timestamp() > datetime.now(timezone.utc).timestamp()) if five_hour_resets else False
        weekly_active = (seven_day_resets.timestamp() > datetime.now(timezone.utc).timestamp()) if seven_day_resets else False

        return UsageData(
            session_percent=float(five_hour.get("utilization", 0.0)),
            session_reset_in=UsageManager.relative_until(five_hour_resets) if five_hour_resets else "—",
            session_active=session_active,
            weekly_percent=float(seven_day.get("utilization", 0.0)),
            weekly_resets_at=UsageManager.absolute_reset(seven_day_resets) if seven_day_resets else "—",
            weekly_active=weekly_active,
            daily_routines=0,
            daily_routines_max=5,
            usage_credits=extra.get("is_enabled", False),
            last_updated="just now"
        )

    # Date helpers
    @staticmethod
    def parse_date(string: str | None) -> datetime | None:
        if not string:
            return None
        # ISO-8601, strip fractional seconds for easy parsing across python versions
        import re
        s = re.sub(r'\.[0-9]+', '', string)
        s = s.replace('Z', '+00:00')
        try:
            return datetime.fromisoformat(s)
        except ValueError:
            return None

    @staticmethod
    def relative_until(date: datetime) -> str:
        secs = (date - datetime.now(timezone.utc)).total_seconds()
        mins = max(0, int(secs / 60))
        h, m = divmod(mins, 60)
        return f"{h}h {m}m" if h > 0 else f"{m}m"

    @staticmethod
    def absolute_reset(date: datetime) -> str:
        # e.g. "Sat 9:00 AM"
        # Linux equivalent of "EEE h:mm a"
        # %a is abbreviated weekday, %I is 12-hour clock (with zero-padding which we can strip), %M is minute, %p is AM/PM
        # Note: on Linux %-I removes padding
        return date.astimezone().strftime("%a %-I:%M %p")

    @staticmethod
    def relative_since(date: datetime) -> str:
        secs = int((datetime.now(timezone.utc) - date).total_seconds())
        if secs < 10: return "just now"
        if secs < 60: return f"{secs}s ago"
        mins = secs // 60
        if mins < 60: return f"{mins}m ago"
        h, m = divmod(mins, 60)
        return f"{h}h {m}m ago" if m > 0 else f"{h}h ago"

    # Token
    @staticmethod
    def _read_oauth_token() -> str | None:
        for path in UsageManager._credential_file_paths():
            try:
                with open(path, "r", encoding="utf-8") as f:
                    data = f.read()
                    token = UsageManager._parse_token(data)
                    if token:
                        return token
            except Exception:
                continue
        return None

    @staticmethod
    def _credential_file_paths() -> list[str]:
        paths = []
        env_dir = os.environ.get("CLAUDE_CONFIG_DIR", "")
        if env_dir:
            paths.append(str(Path(env_dir).expanduser() / ".credentials.json"))
        paths.append(str(Path.home() / ".claude" / ".credentials.json"))
        return paths

    @staticmethod
    def _credentials_exist() -> bool:
        return any(Path(p).exists() for p in UsageManager._credential_file_paths())

    @staticmethod
    def _parse_token(data: str) -> str | None:
        try:
            obj = json.loads(data)
            oauth = obj.get("claudeAiOauth", {})
            token = oauth.get("accessToken", "")
            if not token:
                return None
            expires_at = oauth.get("expiresAt")
            if expires_at is not None:
                secs = expires_at / 1000 if expires_at > 1e12 else expires_at
                if datetime.now(timezone.utc).timestamp() > secs:
                    return None
            return token
        except Exception:
            return None
