#!/bin/sh
# Copyright (c) 2017 Markus Weippert
# GNU General Public License v3.0 (see https://www.gnu.org/licenses/gpl-3.0.txt)

WANT_JSON="1"
PARAMS="
    command=cmd/str
    config/str
    find=find_by=search/any
    keep_keys=keep/any
    key/str
    merge/bool//false
    name/str
    option/str
    replace/bool//false
    section/str
    set_find/bool//true
    type/str
    unique/bool//false
    value/any
"
RESPONSE_VARS="result=_result command config section option"

init() {
    state_path=""
    [ -z "$_ansible_check_mode" ] || state_path="$(mktemp -d)" ||
        fail "could not create state path"
    changes="$(uci_change_hash)"
    case "$_type_keep_keys" in
        object) fail "keep_keys must be list or string";;
        array) json_get_values keep_keys "$_keep_keys" || :;;
    esac
    [ -z "$key" ] &&
        key="${config:+$config${section:+.$section${option:+.$option}}}" ||
        { oIFS="$IFS"; IFS="."; set -- $key; IFS="$oIFS"
            config="$1"; section="$2"; option="$3"; }
    [ -z "$_ansible_diff" -o -z "$config" ] ||
        set_diff "$(uci export "$config")"
    [ -n "$command" ] || { [ -z "$value" ] && command="get" || command="set"; }
}

uci() {
    [ -z "$state_path" ] || set -- -P "$state_path" "$@"
    command uci "$@"
}

uci_change_hash() {
    uci changes | md5
}

uci_result_do() {
    json_set_namespace result
    "$@"
    json_set_namespace params
}

uci_get_safe() {
    local tmp opts
    while [ "${1#-}" != "$1" ]; do opts="$opts $1"; shift; done
    tmp="$(uci $opts show "$1")" || return $?
    echo "${tmp#*=}"
}

uci_check_type() {
    local key="$1"; local type="$2"; local t
    t="$(uci -q get "$key")" || return 1
    [ -n "$type" -a "$t" != "$type" ] || return 0
    fail "$key exists with $t instead of $type"
}

uci_compare_list() {
    local k="${1:-$key}"
    local match="1"
    local keys values v i
    json_get_keys keys
    ! values="$(uci_get_safe -q "$k")" || {
        eval "set -- $values"
        for i in $keys; do
            json_get_var v "$i"
            [ $# -gt 0 -a "$v" = "$1" ] || { match=""; break; }
            shift
        done
        [ $# -eq 0 ] || match=""
        [ -z "$match" ] || return 0
    }
    return 1
}

uci_add() {
    section="${section:-$value}"
    [ -n "$name" -o -z "$type" ] || name="$section"
    type="${type:-$section}"
    [ -n "$type" ] || fail "type required for $command"
    [ -n "$name" ] && {
        uci_check_type "$config.$name" "$type" || {
            try uci add "$config" "$type"
            try uci rename "$config.$_result=$name"
        }
    } || try uci add "$config" "$type"
}

uci_set_list() {
    local k="${1:-$key}"
    local keys v i
    ! uci_compare_list "$k" || return 0
    uci -q delete "$k" || :
    json_get_keys keys
    for i in $keys; do
        json_get_var v "$i"
        try uci add_list "$k=$v"
    done
}

uci_set_dict() {
    local keys k v t
    json_get_keys keys
    keep_keys="$keep_keys $keys"
    for k in $keys; do
        json_get_type t "$k"
        case "$t" in
            array)
                json_select "$k"
                uci_set_list "$key.$k"
                json_select ..;;
            object) fail "cannot set $k to dict";;
            *)
                json_get_var v "$k"
                try uci set "$key.$k=$v";;
        esac
    done
}

uci_set() {
    local var="${1:-value}"
    local var_type
    eval "var_type=\"\$_type_$var\""
    [ -z "$option" ] || keep_keys="$keep_keys $option"
    case "$var_type" in
        array)
            [ -n "$config" -a -n "$section" -a -n "$option" ] ||
                fail "config, section and option required for $command"
            json_select_real "$var"
            uci_set_list
            json_select ..;;
        object)
            [ -n "$config" -a -n "$section" -a -z "$option" ] ||
                fail "config and section but not option required for $command"
            json_select_real "$var"
            uci_set_dict
            json_select ..;;
        *) try "uci set \"\$key=\$$var\"";;
    esac
}

uci_get() {
    local entry
    try uci get "$key"
    eval "set -- $(uci_get_safe -q "$key")"
    json_set_namespace result
    json_add_array result_list
    for entry; do json_add_string . "$entry"; done
    json_close_array
    json_set_namespace params
}

uci_find() {
    local keys i c v k tmp
    case "$_type_find" in
        array|object)
            [ -n "$config" -a -n "$type" ] ||
                fail "config and type required for $command"
            json_select_real find
            json_get_keys keys;;
        *)
            [ -n "$config" -a -n "$type" ] &&
                [ -n "$option" -o "$command" = find_all ] ||
                fail "config, type and option required for $command";;
    esac
    [ "$command" != "find_all" ] || uci_result_do json_add_array result
    type="${type:-$section}"
    section=""; i=0
    while [ -n "$(uci -q get "$config.@$type[$i]")" ]; do
        c="@$type[$((i++))]"
        case "$_type_find" in
            array)
                [ -z "$option" ] && {
                    for k in $keys; do
                        json_get_var v "$k"
                        uci -q get "$config.$c.$v" >/dev/null || continue 2
                    done
                } || {
                    uci_compare_list "$config.$c.$option" || continue
                };;
            object)
                for k in $keys; do
                    json_get_type tmp "$k"
                    case "$tmp" in
                        array)
                            json_select "$k"
                            uci_compare_list "$config.$c.$k" &&
                                tmp="1" || tmp=""
                            json_select ..
                            [ -n "$tmp" ] || continue 2;;
                        object)
                            fail "cannot compare $k with dict";;
                        *)
                            json_get_var v "$k"
                            tmp="$(uci -q get "$config.$c.$k")" &&
                                [ "$tmp" = "$v" ] || continue 2
                    esac
                done;;
            *)
                [ -z "$option" ] || {
                    v="$(uci -q get "$config.$c.$option")" &&
                        [ -z "$find" -o "$find" = "$v" ] || continue
                };;
        esac
        [ "$command" = "find_all" ] || { section="$c"; break; }
        uci_result_do json_add_string . "$c"
    done
    case "$_type_find" in
        array|object) json_select ..;;
    esac
    case "$command" in
        find_all)
            uci_result_do json_close_array
            _result="";;
        *)
            _result="$section"
            [ -n "$section" ] && return 0 || return 1;;
    esac
}

uci_ensure() {
    local keys k v
    [ -n "$name" -o -z "$type" ] || name="$section"
    type="${type:-$section}"
    [ -n "$config" -a -n "$type" ] ||
        fail "config, type and name required for $command"
    [ -n "$name" ] && uci_check_type "$config.$name" "$type" || {
        [ "$_type_find" = "object" -o -n "$option" ] && uci_find && {
            [ -z "$name" ] || try uci rename "$config.$section=$name"
        } || {
            [ "$command" = absent ] && return 0 || uci_add
        }
    }
    section="${name:-$_result}"
    key="$config.$section${option:+.$option}"
    [ "$command" = "absent" ] && {
        [ -z "$_defined_value" ] &&
            final uci delete "$key" ||
            case "$_type_value" in
                array|object)
                    json_select_real value
                    json_get_keys keys
                    for k in $keys; do
                        json_get_var v "$k"
                        case "$_type_value" in
                            array) uci delete "$config.$section.$v";;
                            object) uci delete "$config.$section.$k=$v";;
                        esac
                    done
                    json_select ..;;
                *) uci delete "$config.$section.$value";;
            esac
        return 0
    }
    [ -z "$set_find" -o "$_type_find" != "object" -a -z "$option" ] || {
        uci_set find
        [ "$_type_value" != "object" ] || {
            key="$config.$section"
            option=""
        }
    }
    [ -z "$_defined_value" ] || uci_set
    _result="$section"
}

uci_cleanup_section() {
    case "$command" in
        set|ensure|section) :;;
        *) return 0;;
    esac
    local k v
    [ -n "$replace" -a -n "$config" -a -n "$section" ] || return 0
    for k in $(uci -q show "$config.$section" |
            sed -n 's/^..*\...*\.\([^.][^.]*\)=.*$/\1/p')
            do
        for v in $keep_keys; do
            [ "$k" != "$v" ] || continue 2
        done
        uci -q delete "$config.$section.$k"
    done
}

main() {
    case "$command" in
        batch|import)
            [ -n "$value" ] || fail "value required for $command";;
        add_list|del_list|rename|reorder)
            [ -n "$key" -a -n "$value" ] ||
                fail "key and value required for $command";;
        add|get|delete|ensure|absent)
            [ -n "$key" ] || fail "key required for $command";;
    esac
    case "$command" in
        batch)
            echo "$value" | final uci $command;;
        export|changes|show|commit)
            local cmd="final uci $command"
            [ -z "$key" ] && $cmd || $cmd "$key";;
        import)
            local cmd="final uci ${merge:+-m }$command"
            [ -z "$key" ] && echo "$value" | $cmd ||
                echo "$value" | $cmd "$key";;
        add)
            uci_add; exit 0;;
        add_list)
            [ -z "$unique" ] || {
                eval "set -- $(uci_get_safe -q "$key")"
                for entry; do [ "$entry" = "$value" ] && exit 0; done
            }
            final uci add_list "$key=$value";;
        del_list|reorder)
            final uci $command "$key=$value";;
        get)
            uci_get; exit 0;;
        delete)
            final uci $command "$key${value:+=$value}";;
        rename)
            final uci $command "$key=${name:-$value}";;
        revert)
            [ -z "$key" ] && final rm -f -- "/tmp/.uci"/* 2>/dev/null ||
                final uci $command "$key";;
        set)
            uci_set; exit 0;;
        find|find_all)
            uci_find; exit $?;;
        ensure|section)
            uci_ensure; exit 0;;
        absent)
            [ -n "$_defined_find" ] || {
                uci delete "$key${value:+=$value}"; exit 0
            }
            uci_ensure; exit 0;;
        *) fail "unknown command: $command";;
    esac
}

cleanup() {
    [ "$1" -ne 0 ] || uci_cleanup_section
    [ "$changes" = "$(uci_change_hash)" ] || {
        changed
        [ "$_ansible_verbosity" -lt 2 ] || {
            local _IFS line
            _IFS="$IFS"; IFS="$N"; set -- $(uci changes); IFS="$_IFS"
            json_set_namespace result
            json_add_array changes
            for line; do json_add_string . "$line"; done
            json_close_array
            json_set_namespace params
        }
    }
    [ -z "$_ansible_diff" -o -z "$config" ] ||
        set_diff "" "$(uci export "$config")"
    [ -z "$_ansible_check_mode" -o -z "$state_path" -o ! -d "$state_path" ] ||
        rm -rf "$state_path"
}
