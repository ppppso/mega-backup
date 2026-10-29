"""Settings: /config/settings.json, else environment variable, else schema default.

Mirrors load_settings in scripts/lib.sh; both read the same schema file.
"""
import json
import os
import re
import tempfile

SCHEMA_PATH = os.environ.get("MB_SCHEMA", "/usr/local/share/mega-backup/settings-schema.json")


def config_dir():
    return os.environ.get("MB_CONFIG", "/config")


def settings_path():
    return os.path.join(config_dir(), "settings.json")


def load_schema():
    with open(SCHEMA_PATH) as f:
        return json.load(f)


def normalize(spec, value):
    """Return the validated value in its JSON type, or raise ValueError."""
    t = spec["type"]
    if t == "int":
        if isinstance(value, bool):
            raise ValueError("not a whole number")
        if isinstance(value, str) and re.fullmatch(r"[0-9]+", value.strip()):
            value = int(value.strip())
        if not isinstance(value, int):
            raise ValueError("not a whole number")
        if not spec["min"] <= value <= spec["max"]:
            raise ValueError(f"must be between {spec['min']} and {spec['max']}")
        return value
    if t == "bool":
        if value in (True, "1", "true", "on"):
            return True
        if value in (False, "0", "false", "", None):
            return False
        raise ValueError("not true/false")
    if not isinstance(value, str) or any(ord(c) < 32 for c in value):
        raise ValueError("not valid text")
    if not re.search(spec["pattern"], value):
        raise ValueError("has the wrong format")
    return value


def read_file():
    """The raw settings.json object ({} if missing or invalid)."""
    try:
        with open(settings_path()) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def effective():
    """All settings with the same precedence and fallbacks as the engine."""
    schema = load_schema()
    stored = read_file()
    out = {}
    for key, spec in schema.items():
        env = os.environ.get(key.upper(), "")
        if key in stored:
            value = stored[key]
        elif env != "":
            value = env
        else:
            value = spec["default"]
        try:
            out[key] = normalize(spec, value)
        except ValueError:
            out[key] = spec["default"]
    return out


def update(changes):
    """Validate and merge `changes` into settings.json (atomic write).

    Raises ValueError("<key>: <reason>") on the first invalid value.
    """
    schema = load_schema()
    data = read_file()
    for key, value in changes.items():
        if key not in schema:
            raise ValueError(f"{key}: unknown setting")
        try:
            data[key] = normalize(schema[key], value)
        except ValueError as e:
            raise ValueError(f"{key}: {e}") from None
    fd, tmp = tempfile.mkstemp(dir=config_dir(), prefix=".settings.")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2, sort_keys=True)
            f.write("\n")
        os.replace(tmp, settings_path())
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
