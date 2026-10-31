#!/usr/bin/env bash
# Parse the optional GMS provider switch for the canonical ROM build engine.
# Source only; the caller supplies usage() and die().

GMS_PROVIDER_PARSE_ERROR=""
GMS_PROVIDER_SHOW_HELP=0

prompt_gms_provider() {
  local provider_name="$1"
  local -n provider_ref="$provider_name"
  local selection

  while true; do
    cat <<'EOF'

Select GMS (App Store) Integration:

  1) MicroG - Open-source Play Services, better privacy
  2) MindTheGapps - Proprietary Google Play Services, better compatibility
  3) DeGoogled, no App Store

EOF
    printf 'Selection [1-3]: '
    if ! IFS= read -r selection; then
      GMS_PROVIDER_PARSE_ERROR="no provider selection received"
      return 1
    fi

    case "${selection,,}" in
      1|microg) provider_ref="microg"; return 0 ;;
      2|mtg|mindthegapps) provider_ref="mtg"; return 0 ;;
      3|none|no|de-googled|degoogled) provider_ref="none"; return 0 ;;
      *) printf 'Please enter 1, 2, or 3.\n\n' >&2 ;;
    esac
  done
}

parse_gms_provider_arguments() {
  local provider_name="$1"
  local targets_name="$2"
  shift 2

  local -n provider_ref="$provider_name"
  local -n targets_ref="$targets_name"
  local requested_provider=""
  local parse_options=1
  local argument

  provider_ref="none"
  targets_ref=()
  GMS_PROVIDER_PARSE_ERROR=""
  GMS_PROVIDER_SHOW_HELP=0

  for argument in "$@"; do
    if [[ "$parse_options" == "1" ]]; then
      case "$argument" in
        --microg) requested_provider="microg" ;;
        --mtg) requested_provider="mtg" ;;
        -h|--help|help) GMS_PROVIDER_SHOW_HELP=1 ;;
        --) parse_options=0; continue ;;
        -*)
          GMS_PROVIDER_PARSE_ERROR="unknown option '$argument'; expected --microg or --mtg"
          return 2
          ;;
        *) targets_ref+=("$argument"); continue ;;
      esac

      if [[ "$argument" == "--microg" || "$argument" == "--mtg" ]]; then
        if [[ "$provider_ref" != "none" && "$provider_ref" != "$requested_provider" ]]; then
          GMS_PROVIDER_PARSE_ERROR="--microg and --mtg cannot be used together"
          return 2
        fi
        provider_ref="$requested_provider"
      fi
    else
      targets_ref+=("$argument")
    fi
  done
}
