"""Offline Flutter presentation checks, bundled in each independently installed skill."""

import math
from typing import Any

CONDITIONS = {"gt", "ge", "lt", "le", "eq", "ne", "in_range", "outside_range"}


def finite(value: Any) -> bool:
    try:
        return type(value) in (int, float) and math.isfinite(value)
    except OverflowError:
        return False


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def overview_summary(data: dict[str, Any]) -> dict[str, Any]:
    """Summarize already validated data; absence and intentional emptiness differ."""
    draft = {**data.get("draft", {}),
             **data.get("registers_options", {}).get("flutter", {}).get("draft", {})}
    blocks = draft.get("map_overview", {}).get("blocks", [])
    items = [item for block in blocks for item in block["items"]]
    active_items = sum(len(block["items"]) for block in blocks if block.get("enabled", True))
    return {"status": "missing" if "map_overview" not in draft else
            "configured" if active_items else "empty",
            "blocks": len(blocks), "items": len(items), "active_items": active_items,
            "color_rules": sum(len(item.get("rules", [])) for item in items),
            "legacy_references": sum("row" in item for item in items)}


def validate_presentation(data: dict[str, Any]) -> list[str]:
    """Validate optional overview data without rewriting it or requiring row defaults."""
    errors: list[str] = []

    def check(ok: bool, message: str) -> None:
        if not ok:
            errors.append(message)

    rows = data.get("registers", [])
    if not isinstance(rows, list):
        return errors  # The caller validates the public-template envelope.
    ids: dict[str, int] = {}
    for i, row in enumerate(rows):
        if not isinstance(row, dict) or "overview_id" not in row:
            continue
        identity = row["overview_id"]
        if not isinstance(identity, str) or not identity.strip():
            errors.append(f"registers[{i}].overview_id must be a non-empty string")
        else:
            check(identity not in ids, f"registers[{i}].overview_id is duplicated: {identity}")
            ids[identity] = i

    # NativeCatalog merges these drafts shallowly, with the legacy extension last.
    drafts = [("draft", data.get("draft", {}))]
    options = data.get("registers_options", {})
    if isinstance(options, dict):
        extra = options.get("flutter", {})
        if isinstance(extra, dict):
            drafts.append(("registers_options.flutter.draft", extra.get("draft", {})))
        else:
            errors.append("registers_options.flutter must be an object")
    else:
        errors.append("registers_options must be an object")
    effective: dict[str, Any] = {}
    for path, draft in drafts:
        if isinstance(draft, dict):
            effective.update(draft)
        else:
            errors.append(f"{path} must be an object")
    if "map_split_ratio" in effective:
        ratio = effective["map_split_ratio"]
        check(finite(ratio) and .28 <= ratio <= .62,
              "map_split_ratio must be a finite number in 0.28..0.62")
    if "map_overview" not in effective:
        return errors
    overview = effective["map_overview"]
    if not isinstance(overview, dict) or not isinstance(overview.get("blocks"), list):
        return [*errors, "map_overview.blocks must be an array"]
    for b, block in enumerate(overview["blocks"]):
        path = f"map_overview.blocks[{b}]"
        if not isinstance(block, dict):
            errors.append(f"{path} must be an object")
            continue
        check(isinstance(block.get("name"), str) and bool(block["name"].strip()),
              f"{path}.name must be a non-empty string")
        if "enabled" in block:
            check(type(block["enabled"]) is bool, f"{path}.enabled must be boolean")
        if not isinstance(block.get("items"), list):
            errors.append(f"{path}.items must be an array")
            continue
        selected: set[int] = set()
        for j, item in enumerate(block["items"]):
            at = f"{path}.items[{j}]"
            if not isinstance(item, dict):
                errors.append(f"{at} must be an object")
                continue
            target = None
            if "row_id" in item and "row" not in item:
                identity = item["row_id"]
                if isinstance(identity, str) and identity in ids:
                    target = ids[identity]
                else:
                    errors.append(f"{at}.row_id must reference an existing overview_id")
            elif "row" in item and "row_id" not in item:
                index = item["row"]
                if type(index) is int and 0 <= index < len(rows):
                    target = index
                else:
                    errors.append(f"{at}.row must be a valid zero-based register index")
            else:
                errors.append(f"{at} requires exactly one of row_id or legacy row")
            if target is not None:
                check(target not in selected, f"{at}: duplicate register in block")
                selected.add(target)
            if "label" in item:
                check(isinstance(item["label"], str), f"{at}.label must be a string")
            if "rules" not in item:
                continue
            if not isinstance(item["rules"], list):
                errors.append(f"{at}.rules must be an array")
                continue
            for k, rule in enumerate(item["rules"]):
                rule_at = f"{at}.rules[{k}]"
                if not isinstance(rule, dict):
                    errors.append(f"{rule_at} must be an object")
                    continue
                condition = rule.get("condition")
                check(isinstance(condition, str) and condition in CONDITIONS,
                      f"{rule_at}.condition is invalid")
                check(finite(rule.get("value")), f"{rule_at}.value must be finite")
                if condition in ("in_range", "outside_range"):
                    check(finite(rule.get("value2")), f"{rule_at}.value2 must be finite")
                else:
                    check(rule.get("value2") is None,
                          f"{rule_at}.value2 is only allowed for range conditions")
                check(rule.get("color", "red") in ("red", "yellow"),
                      f"{rule_at}.color must be red or yellow")
                for flag in ("log", "sound"):
                    if flag in rule:
                        check(type(rule[flag]) is bool, f"{rule_at}.{flag} must be boolean")
    return errors
