import Foundation

/// Result of pushing one provider's credentials onto a host's Hermes
/// config. `steps_done` is a discriminated set the UI can pattern-match
/// on without wading through `errors` for the happy path.
struct ProviderVMInstallResult: Decodable, Equatable, Sendable {
    let success: Bool
    let errors: [String]
    let steps_done: [String]
    let provider_slug: String?
    let active_model: String?

    var didWriteEnv: Bool { steps_done.contains("env_written") }
    var didWriteCustomProvider: Bool { steps_done.contains("custom_provider_written") }
    var didActivate: Bool { steps_done.contains("activated") }
    var didWriteAuthActive: Bool { steps_done.contains("auth_active_set") }
    var keyWasUnchanged: Bool { steps_done.contains("env_unchanged") }
}

/// What we're asking the host to do. Three paths:
///   - `.install`: write the API key (and custom_provider entry, if any)
///   - `.activate`: switch the active model in `config.yaml.model`
///   - `.uninstall`: remove the env var (and custom_provider entry)
enum ProviderVMInstallAction: Sendable {
    case install(apiKey: String, activateModel: String?)
    case activate(model: String)
    case uninstall
    case status
}

/// Pushes / removes provider credentials in the host's `~/.hermes/.env`
/// + matching entry in `~/.hermes/config.yaml`. Hermes itself reads
/// these on its next chat turn — no daemon restart needed.
///
/// Why we don't just shell `hermes config set`: we'd still need to
/// generate the YAML for `custom_providers` (Hermes' interactive
/// `hermes model` wizard is the only path that writes those, and we
/// can't drive it non-interactively over SSH). So we own the file
/// updates ourselves. PyYAML is preferred when available, but locked-down
/// hosts still get a small fallback parser for the config shape OS1 owns.
final class ProviderVMInstaller: @unchecked Sendable {
    private let orgoTransport: OrgoTransport
    private let multiplexed: any RemoteTransport

    init(orgoTransport: OrgoTransport, multiplexed: any RemoteTransport) {
        self.orgoTransport = orgoTransport
        self.multiplexed = multiplexed
    }

    func run(
        action: ProviderVMInstallAction,
        provider: ProviderCatalogEntry,
        on connection: ConnectionProfile
    ) async throws -> ProviderVMInstallResult {
        let script = Self.makeScript(provider: provider, action: action)
        switch connection.transport {
        case .orgo:
            return try await orgoTransport.executeLongPython(
                on: connection,
                pythonScript: script,
                serverTimeoutSeconds: 60,
                responseType: ProviderVMInstallResult.self
            )
        case .ssh:
            return try await multiplexed.executeJSON(
                on: connection,
                pythonScript: script,
                responseType: ProviderVMInstallResult.self
            )
        }
    }
}

extension ProviderVMInstaller {
    /// Generates the Python source. Exposed for tests so we can run a
    /// syntax-check (`python -c "compile(open(path).read(), 'x', 'exec')"`)
    /// against it without hitting a real host.
    static func makeScript(
        provider: ProviderCatalogEntry,
        action: ProviderVMInstallAction
    ) -> String {
        // Encode all string inputs as base64 so quoting is impossible to
        // break. Same trick as OrgoHermesInstaller — base64 only
        // contains [A-Za-z0-9+/=], safe inside any Python literal.
        let slugB64 = b64(provider.slug)
        let envVarB64 = b64(provider.envVar)
        let baseURLB64 = b64(provider.baseURL.absoluteString)

        let kindLiteral: String
        let configNameB64: String
        switch provider.kind {
        case .builtin(let typeKey):
            kindLiteral = "\"builtin\""
            configNameB64 = b64(typeKey)
        case .customProvider(let configName):
            kindLiteral = "\"custom\""
            configNameB64 = b64(configName)
        }

        let actionLiteral: String
        let apiKeyB64: String
        let activateModelB64: String
        switch action {
        case .install(let apiKey, let activateModel):
            actionLiteral = "\"install\""
            apiKeyB64 = b64(apiKey)
            activateModelB64 = b64(activateModel ?? "")
        case .activate(let model):
            actionLiteral = "\"activate\""
            apiKeyB64 = b64("")
            activateModelB64 = b64(model)
        case .uninstall:
            actionLiteral = "\"uninstall\""
            apiKeyB64 = b64("")
            activateModelB64 = b64("")
        case .status:
            actionLiteral = "\"status\""
            apiKeyB64 = b64("")
            activateModelB64 = b64("")
        }

        return #"""
        import json
        import os
        import sys
        from base64 import b64decode

        ACTION = \#(actionLiteral)
        KIND = \#(kindLiteral)
        slug = b64decode("\#(slugB64)").decode("utf-8")
        env_var = b64decode("\#(envVarB64)").decode("utf-8")
        base_url = b64decode("\#(baseURLB64)").decode("utf-8")
        config_name = b64decode("\#(configNameB64)").decode("utf-8")
        api_key = b64decode("\#(apiKeyB64)").decode("utf-8")
        activate_model = b64decode("\#(activateModelB64)").decode("utf-8")

        steps = []
        errors = []
        active_model_value = None

        hermes_dir = os.path.join(os.path.expanduser("~"), ".hermes")
        env_path = os.path.join(hermes_dir, ".env")
        config_path = os.path.join(hermes_dir, "config.yaml")
        auth_json_path = os.path.join(hermes_dir, "auth.json")

        def emit(payload):
            payload.setdefault("provider_slug", slug)
            payload.setdefault("active_model", active_model_value)
            print(json.dumps(payload))
            sys.exit(0)

        # ---- helpers ----------------------------------------------------

        def ensure_yaml():
            try:
                import yaml  # noqa: F401
                return True
            except ImportError:
                pass
            try:
                import subprocess
                subprocess.run(
                    [sys.executable, "-m", "pip", "install", "--quiet", "--user", "pyyaml"],
                    check=True,
                    timeout=45,
                    capture_output=True,
                )
                import yaml  # noqa: F401
                return True
            except Exception as exc:
                # Tests and locked-down hosts may run with HOME pointed at
                # an empty sandbox, which hides user-site PyYAML and can make
                # pip unavailable. We can still write the small config shape
                # OS1 owns without PyYAML; existing complex config files still
                # need PyYAML to be preserved exactly.
                return True

        def dump_config_fallback(data):
            # JSON is valid YAML 1.2 and keeps the fallback dependency-free.
            return json.dumps(data, indent=2) + "\n"

        def strip_inline_comment(text):
            quote = None
            escaped = False
            for i, ch in enumerate(text):
                if escaped:
                    escaped = False
                    continue
                if ch == "\\" and quote == '"':
                    escaped = True
                    continue
                if ch in ("'", '"'):
                    if quote == ch:
                        quote = None
                    elif quote is None:
                        quote = ch
                    continue
                if ch == "#" and quote is None and (i == 0 or text[i - 1].isspace()):
                    return text[:i].rstrip()
            return text.rstrip()

        def split_top_level_csv(text):
            parts = []
            start = 0
            depth = 0
            quote = None
            escaped = False
            for i, ch in enumerate(text):
                if escaped:
                    escaped = False
                    continue
                if ch == "\\" and quote == '"':
                    escaped = True
                    continue
                if ch in ("'", '"'):
                    if quote == ch:
                        quote = None
                    elif quote is None:
                        quote = ch
                    continue
                if quote is not None:
                    continue
                if ch in "[{":
                    depth += 1
                elif ch in "]}":
                    depth -= 1
                elif ch == "," and depth == 0:
                    parts.append(text[start:i].strip())
                    start = i + 1
            parts.append(text[start:].strip())
            return [part for part in parts if part]

        def parse_scalar_fallback(value):
            value = value.strip()
            if value == "":
                return ""
            if (value.startswith('"') and value.endswith('"')) or (value.startswith("'") and value.endswith("'")):
                try:
                    return json.loads(value) if value.startswith('"') else value[1:-1].replace("''", "'")
                except Exception:
                    return value[1:-1]
            lowered = value.lower()
            if lowered in ("true", "false"):
                return lowered == "true"
            if lowered in ("null", "none", "~"):
                return None
            if value.startswith("[") and value.endswith("]"):
                try:
                    return json.loads(value)
                except Exception:
                    inner = value[1:-1].strip()
                    return [] if not inner else [parse_scalar_fallback(part) for part in split_top_level_csv(inner)]
            if value.startswith("{") and value.endswith("}"):
                try:
                    loaded = json.loads(value)
                    return loaded
                except Exception:
                    pass
            try:
                if any(ch in value for ch in (".", "e", "E")):
                    return float(value)
                return int(value)
            except ValueError:
                return value

        def split_key_value_fallback(text):
            quote = None
            escaped = False
            for i, ch in enumerate(text):
                if escaped:
                    escaped = False
                    continue
                if ch == "\\" and quote == '"':
                    escaped = True
                    continue
                if ch in ("'", '"'):
                    if quote == ch:
                        quote = None
                    elif quote is None:
                        quote = ch
                    continue
                if ch == ":" and quote is None:
                    key = text[:i].strip()
                    value = text[i + 1:].strip()
                    if not key:
                        raise ValueError(f"missing key before ':' in line: {text}")
                    return key.strip('"').strip("'"), value
            raise ValueError(f"expected 'key: value' in line: {text}")

        def parse_config_fallback(text):
            stripped = text.strip()
            if not stripped:
                return {}
            try:
                loaded = json.loads(text)
                if not isinstance(loaded, dict):
                    raise ValueError("top-level config must be a mapping")
                return loaded
            except json.JSONDecodeError:
                pass

            lines = []
            for line_number, raw in enumerate(text.splitlines(), start=1):
                if "\t" in raw:
                    raise ValueError(f"tabs are not supported in config.yaml fallback parser at line {line_number}")
                if not raw.strip() or raw.lstrip().startswith("#"):
                    continue
                indent = len(raw) - len(raw.lstrip(" "))
                content = strip_inline_comment(raw[indent:])
                if content:
                    lines.append((line_number, indent, content))
            if not lines:
                return {}

            def parse_block(index, indent):
                _, current_indent, content = lines[index]
                if current_indent != indent:
                    raise ValueError(f"unexpected indentation at line {lines[index][0]}")
                if content == "-" or content.startswith("- "):
                    return parse_sequence(index, indent)
                return parse_mapping(index, indent)

            def parse_mapping(index, indent):
                result = {}
                while index < len(lines):
                    line_number, current_indent, content = lines[index]
                    if current_indent < indent:
                        break
                    if current_indent > indent:
                        raise ValueError(f"unexpected indentation at line {line_number}")
                    if content == "-" or content.startswith("- "):
                        break
                    key, value = split_key_value_fallback(content)
                    index += 1
                    if value:
                        result[key] = parse_scalar_fallback(value)
                    elif index < len(lines) and lines[index][1] > current_indent:
                        result[key], index = parse_block(index, lines[index][1])
                    else:
                        result[key] = {}
                return result, index

            def parse_sequence(index, indent):
                result = []
                while index < len(lines):
                    line_number, current_indent, content = lines[index]
                    if current_indent < indent:
                        break
                    if current_indent > indent:
                        raise ValueError(f"unexpected indentation at line {line_number}")
                    if not (content == "-" or content.startswith("- ")):
                        break
                    item = content[1:].strip()
                    index += 1
                    if not item:
                        if index < len(lines) and lines[index][1] > current_indent:
                            value, index = parse_block(index, lines[index][1])
                        else:
                            value = None
                    elif ":" in item:
                        key, value_text = split_key_value_fallback(item)
                        value = {}
                        value[key] = parse_scalar_fallback(value_text) if value_text else {}
                        while index < len(lines) and lines[index][1] > current_indent:
                            nested, index = parse_block(index, lines[index][1])
                            if not isinstance(nested, dict):
                                raise ValueError(f"expected mapping fields for list item after line {line_number}")
                            value.update(nested)
                    else:
                        value = parse_scalar_fallback(item)
                    result.append(value)
                return result, index

            parsed, index = parse_block(0, lines[0][1])
            if index != len(lines):
                raise ValueError(f"could not parse config.yaml near line {lines[index][0]}")
            if not isinstance(parsed, dict):
                raise ValueError("top-level config must be a mapping")
            return parsed

        def read_env_file():
            entries = []
            if not os.path.exists(env_path):
                return entries
            try:
                with open(env_path, "r") as fh:
                    for raw in fh:
                        line = raw.rstrip("\n")
                        entries.append(line)
            except Exception as exc:
                errors.append(f"Couldn't read existing .env: {exc}")
            return entries

        def write_env_file(entries):
            try:
                os.makedirs(hermes_dir, exist_ok=True)
                tmp_path = env_path + ".tmp"
                with open(tmp_path, "w") as fh:
                    for line in entries:
                        fh.write(line + "\n")
                os.replace(tmp_path, env_path)
                try:
                    os.chmod(env_path, 0o600)
                except Exception:
                    pass
                return True
            except Exception as exc:
                errors.append(f"Failed to write .env: {exc}")
                return False

        def upsert_env(entries, key, value):
            quoted = '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'
            line = f"{key}={quoted}"
            for i, existing in enumerate(entries):
                # Match KEY= at start of line, ignoring leading whitespace.
                stripped = existing.lstrip()
                if stripped.startswith(f"{key}="):
                    if existing == line:
                        return entries, False
                    entries[i] = line
                    return entries, True
            entries.append(line)
            return entries, True

        def remove_env(entries, key):
            new_entries = []
            removed = False
            for existing in entries:
                stripped = existing.lstrip()
                if stripped.startswith(f"{key}="):
                    removed = True
                    continue
                new_entries.append(existing)
            return new_entries, removed

        def env_has_key(entries, key):
            for existing in entries:
                if existing.lstrip().startswith(f"{key}="):
                    return True
            return False

        def load_config():
            if not os.path.exists(config_path):
                return {}
            try:
                with open(config_path, "r") as fh:
                    config_text = fh.read()
            except Exception as exc:
                errors.append(f"Couldn't read existing config.yaml: {exc}")
                return None
            try:
                import yaml as _yaml
                loaded = _yaml.safe_load(config_text) or {}
                if not isinstance(loaded, dict):
                    errors.append("Couldn't read existing config.yaml: top-level config must be a mapping")
                    return None
                return loaded
            except ImportError:
                pass
            except Exception as exc:
                errors.append(f"Couldn't parse existing config.yaml with PyYAML: {exc}")
                return None
            try:
                return parse_config_fallback(config_text)
            except Exception as exc:
                errors.append(f"Couldn't parse existing config.yaml without PyYAML: {exc}")
                return None

        def write_config(data):
            try:
                os.makedirs(hermes_dir, exist_ok=True)
                tmp_path = config_path + ".tmp"
                with open(tmp_path, "w") as fh:
                    try:
                        import yaml as _yaml
                        _yaml.safe_dump(data, fh, sort_keys=False, default_flow_style=False)
                    except Exception:
                        fh.write(dump_config_fallback(data))
                os.replace(tmp_path, config_path)
                try:
                    os.chmod(config_path, 0o600)
                except Exception:
                    pass
                return True
            except Exception as exc:
                errors.append(f"Failed to write config.yaml: {exc}")
                return False

        def upsert_custom_provider(data):
            # `custom_providers` is an ordered list of dicts, each with
            # `name`, `base_url`, `key_env`. Replace by name; append if
            # absent. Hermes reads it as-is.
            target = {
                "name": config_name,
                "base_url": base_url,
                "key_env": env_var,
            }
            providers = data.get("custom_providers")
            if not isinstance(providers, list):
                providers = []
            replaced = False
            for i, item in enumerate(providers):
                if isinstance(item, dict) and item.get("name") == config_name:
                    if item == target:
                        return data, False
                    providers[i] = target
                    replaced = True
                    break
            if not replaced:
                providers.append(target)
            data["custom_providers"] = providers
            return data, True

        def remove_custom_provider(data):
            providers = data.get("custom_providers")
            if not isinstance(providers, list):
                return data, False
            new_list = [item for item in providers if not (isinstance(item, dict) and item.get("name") == config_name)]
            if len(new_list) == len(providers):
                return data, False
            if new_list:
                data["custom_providers"] = new_list
            else:
                data.pop("custom_providers", None)
            return data, True

        def upsert_active_model(data, model_id):
            # Mirrors Hermes' own `_update_config_for_provider`
            # (hermes_cli/auth.py): set `provider` to the resolved id and
            # clear stale `api_key` / `api_mode`. There is no
            # `model.custom_provider` field in Hermes' schema.
            #
            # For built-ins (anthropic, openrouter, kimi-coding, zai)
            # `config_name` matches a key in Hermes' PROVIDER_REGISTRY,
            # whose `inference_base_url` is the source of truth — we
            # *pop* `base_url` so the registry default wins. (Our catalog
            # baseURL field is the validation-probe URL, which for some
            # providers like Anthropic includes `/v1` and would otherwise
            # double the path at request time — runtime_provider.py
            # honors `model.base_url` when set; see lines 1141-1145 and
            # 1281-1285.)
            #
            # For OpenAI / Fireworks (custom) `config_name` matches the
            # `name` field of our custom_providers entry. Hermes resolves
            # those via `_get_named_custom_provider`, which reads the
            # base_url from the entry — but we also persist it under
            # `model.base_url` to match the canonical write shape.
            model_section = data.get("model") if isinstance(data.get("model"), dict) else {}
            model_section = dict(model_section)
            model_section["default"] = model_id
            model_section["provider"] = config_name
            if KIND == "builtin":
                model_section.pop("base_url", None)
            else:
                model_section["base_url"] = base_url.rstrip("/")
            model_section.pop("api_key", None)
            model_section.pop("api_mode", None)
            data["model"] = model_section
            return data

        def read_auth_json():
            if not os.path.exists(auth_json_path):
                return {}
            try:
                with open(auth_json_path, "r") as fh:
                    loaded = json.load(fh)
                    return loaded if isinstance(loaded, dict) else {}
            except Exception:
                # Malformed auth.json — Hermes itself tolerates re-init,
                # but we shouldn't blow up the whole install over it.
                return {}

        def write_auth_json(auth_data):
            try:
                os.makedirs(hermes_dir, exist_ok=True)
                tmp_path = auth_json_path + ".tmp"
                with open(tmp_path, "w") as fh:
                    fh.write(json.dumps(auth_data, indent=2) + "\n")
                os.replace(tmp_path, auth_json_path)
                try:
                    os.chmod(auth_json_path, 0o600)
                except Exception:
                    pass
                return True
            except Exception as exc:
                errors.append(f"Failed to write auth.json: {exc}")
                return False

        def upsert_active_provider_in_auth():
            # Sets `active_provider` without disturbing other auth.json
            # state (OAuth credential pools, etc.). Hermes will overwrite
            # version/updated_at on its next save.
            auth_data = read_auth_json()
            if auth_data.get("active_provider") == config_name:
                return False
            auth_data["active_provider"] = config_name
            return write_auth_json(auth_data)

        def clear_active_provider_in_auth():
            # Only clear when *we* are the active provider. Otherwise
            # leave the user's other selection alone.
            auth_data = read_auth_json()
            if auth_data.get("active_provider") not in (config_name, slug):
                return False
            auth_data["active_provider"] = None
            return write_auth_json(auth_data)

        # ---- branches ---------------------------------------------------

        if ACTION == "status":
            entries = read_env_file()
            if env_has_key(entries, env_var):
                steps.append("env_present")
            data = load_config()
            if data is None:
                emit({"success": False, "errors": errors, "steps_done": steps})
            if KIND == "custom":
                providers = data.get("custom_providers") or []
                for item in providers:
                    if isinstance(item, dict) and item.get("name") == config_name:
                        steps.append("custom_provider_present")
                        break
            model_section = data.get("model") if isinstance(data.get("model"), dict) else {}
            if isinstance(model_section, dict):
                # Only surface `active_model` when THIS provider is the
                # one Hermes is configured to use. Otherwise every row
                # whose env var is on file would parrot the global
                # active model and mislead the user.
                if model_section.get("provider") == config_name:
                    steps.append("model_provider_active")
                    if model_section.get("default"):
                        active_model_value = model_section.get("default")
            auth_data = read_auth_json()
            if auth_data.get("active_provider") == config_name:
                steps.append("auth_active")
            emit({"success": True, "errors": errors, "steps_done": steps})

        if ACTION == "install":
            if not api_key.strip():
                errors.append("install requested without an API key")
                emit({"success": False, "errors": errors, "steps_done": steps})

            entries = read_env_file()
            entries, env_changed = upsert_env(entries, env_var, api_key)
            if not write_env_file(entries):
                emit({"success": False, "errors": errors, "steps_done": steps})
            steps.append("env_written" if env_changed else "env_unchanged")

            if KIND == "custom":
                if not ensure_yaml():
                    emit({"success": False, "errors": errors, "steps_done": steps})
                data = load_config()
                if data is None:
                    emit({"success": False, "errors": errors, "steps_done": steps})
                data, provider_changed = upsert_custom_provider(data)
                if provider_changed:
                    if not write_config(data):
                        emit({"success": False, "errors": errors, "steps_done": steps})
                    steps.append("custom_provider_written")
                else:
                    steps.append("custom_provider_unchanged")

            if activate_model.strip():
                if not ensure_yaml():
                    emit({"success": False, "errors": errors, "steps_done": steps})
                data = load_config()
                if data is None:
                    emit({"success": False, "errors": errors, "steps_done": steps})
                data = upsert_active_model(data, activate_model)
                if not write_config(data):
                    emit({"success": False, "errors": errors, "steps_done": steps})
                active_model_value = activate_model
                steps.append("activated")
                if upsert_active_provider_in_auth():
                    steps.append("auth_active_set")

            emit({"success": len(errors) == 0, "errors": errors, "steps_done": steps})

        if ACTION == "activate":
            if not activate_model.strip():
                errors.append("activate requested without a model id")
                emit({"success": False, "errors": errors, "steps_done": steps})
            if not ensure_yaml():
                emit({"success": False, "errors": errors, "steps_done": steps})
            data = load_config()
            if data is None:
                emit({"success": False, "errors": errors, "steps_done": steps})
            data = upsert_active_model(data, activate_model)
            if not write_config(data):
                emit({"success": False, "errors": errors, "steps_done": steps})
            active_model_value = activate_model
            steps.append("activated")
            if upsert_active_provider_in_auth():
                steps.append("auth_active_set")
            emit({"success": True, "errors": errors, "steps_done": steps})

        if ACTION == "uninstall":
            entries = read_env_file()
            entries, removed = remove_env(entries, env_var)
            if removed:
                if not write_env_file(entries):
                    emit({"success": False, "errors": errors, "steps_done": steps})
                steps.append("env_removed")
            if KIND == "custom":
                if not ensure_yaml():
                    emit({"success": False, "errors": errors, "steps_done": steps})
                data = load_config()
                if data is None:
                    emit({"success": False, "errors": errors, "steps_done": steps})
                data, removed_cp = remove_custom_provider(data)
                if removed_cp:
                    if not write_config(data):
                        emit({"success": False, "errors": errors, "steps_done": steps})
                    steps.append("custom_provider_removed")
            if clear_active_provider_in_auth():
                steps.append("auth_active_cleared")
            emit({"success": True, "errors": errors, "steps_done": steps})

        # Unknown action — shouldn't happen since we cover every
        # ProviderVMInstallAction case at compile time.
        errors.append(f"Unknown action: {ACTION}")
        emit({"success": False, "errors": errors, "steps_done": steps})
        """#
    }

    private static func b64(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }
}
