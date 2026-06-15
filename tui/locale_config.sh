#!/usr/bin/env bash
# tui/locale_config.sh — Timezone, locale, console keymap (FreeBSD)
#
# FreeBSD specifics vs the Linux siblings:
#   - Timezone is applied at post-install via `tzsetup "${TIMEZONE}"` (writes
#     /etc/localtime + /var/db/zoneinfo); zone names are the standard
#     /usr/share/zoneinfo Region/City strings, same as Linux.
#   - Console keymap is a vt(4) keymap file under /usr/share/vt/keymaps and
#     carries a `.kbd` suffix (e.g. us.kbd, pl.kbd) — NOT the bare X-style
#     names Linux uses. It is set via `sysrc keymap="${KEYMAP}"`.
#   - There is NO /etc/locale.conf on FreeBSD. The UTF-8 locale is applied via
#     a login.conf class (charset/lang caps) + `cap_mkdb` and `pw usermod -L`.
#     For v0.1 every UTF-8 locale maps to the single "english" class — the class
#     only pins charset=UTF-8 + lang=<LOCALE>, so one generic class is enough.
source "${LIB_DIR}/protection.sh"

screen_locale_config() {
    # --- Timezone ---------------------------------------------------------
    # Free-form Region/City; applied later by tzsetup. Default Europe/Warsaw.
    local tz
    tz=$(dialog_inputbox "Timezone" \
        "Enter your timezone (Region/City), e.g. Europe/Warsaw, America/New_York.\n\n\
Tip: run 'ls /usr/share/zoneinfo/' on the live system to list zones." \
        "${TIMEZONE:-Europe/Warsaw}") || return "${TUI_BACK}"

    TIMEZONE="${tz}"
    export TIMEZONE
    # Apply to the live environment too, so installer logs carry the right time.
    export TZ="${TIMEZONE}"

    # --- System locale ----------------------------------------------------
    # FreeBSD ships these UTF-8 locales in base; pick one (default en_US.UTF-8).
    local locale_choice
    locale_choice=$(dialog_menu "System Locale" \
        "en_US.UTF-8" "English (US)" \
        "en_GB.UTF-8" "English (UK)" \
        "pl_PL.UTF-8" "Polish" \
        "de_DE.UTF-8" "German" \
        "fr_FR.UTF-8" "French" \
        "es_ES.UTF-8" "Spanish" \
        "it_IT.UTF-8" "Italian" \
        "pt_BR.UTF-8" "Portuguese (Brazil)" \
        "ru_RU.UTF-8" "Russian" \
        "ja_JP.UTF-8" "Japanese" \
        "zh_CN.UTF-8" "Chinese (Simplified)" \
        "ko_KR.UTF-8" "Korean" \
        "custom"      "Enter a custom locale") \
        || return "${TUI_BACK}"

    if [[ "${locale_choice}" == "custom" ]]; then
        locale_choice=$(dialog_inputbox "Custom Locale" \
            "Enter a UTF-8 locale name (e.g. nl_NL.UTF-8):" \
            "${LOCALE:-en_US.UTF-8}") || return "${TUI_BACK}"
    fi

    LOCALE="${locale_choice}"
    export LOCALE

    # Derive the login.conf class name. v0.1: one generic "english" class for any
    # UTF-8 locale — the class only sets charset=UTF-8 + lang=${LOCALE}, so the
    # name is cosmetic and a single class covers every selection above.
    LOCALE_CLASS="english"
    export LOCALE_CLASS

    # --- Console keymap (vt) ----------------------------------------------
    # vt(4) keymaps live in /usr/share/vt/keymaps and use the .kbd suffix.
    # Tags here are the exact filenames passed to `sysrc keymap=...`.
    local keymap_choice
    keymap_choice=$(dialog_menu "Console Keymap" \
        "us.kbd"    "US English" \
        "uk.kbd"    "UK English" \
        "pl.kbd"    "Polish" \
        "de.kbd"    "German" \
        "fr.kbd"    "French" \
        "es.kbd"    "Spanish" \
        "it.kbd"    "Italian" \
        "br275.kbd" "Brazilian Portuguese" \
        "ru.kbd"    "Russian" \
        "jp.kbd"    "Japanese" \
        "custom"    "Enter a custom keymap") \
        || return "${TUI_BACK}"

    if [[ "${keymap_choice}" == "custom" ]]; then
        # Accept either "pl" or "pl.kbd"; normalize to the .kbd filename below.
        keymap_choice=$(dialog_inputbox "Custom Keymap" \
            "Enter a vt keymap name (with or without .kbd), e.g. pl.kbd:" \
            "${KEYMAP:-us.kbd}") || return "${TUI_BACK}"
    fi

    # Normalize: ensure the .kbd suffix that sysrc/vt expect.
    if [[ -n "${keymap_choice}" && "${keymap_choice}" != *.kbd ]]; then
        keymap_choice="${keymap_choice}.kbd"
    fi

    KEYMAP="${keymap_choice}"
    export KEYMAP

    einfo "Timezone: ${TIMEZONE}, Locale: ${LOCALE} (class ${LOCALE_CLASS}), Keymap: ${KEYMAP}"
    return "${TUI_NEXT}"
}
