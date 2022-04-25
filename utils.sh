die() {
  if [ "${1:-}" ]; then
    >&2 echo "$1"
  fi
  exit 1
}

get_arg() {
  local is_required
  case "$1" in
    required)
      is_required=true
    ;;
    optional)
      is_required=false
    ;;
    *)
      die "Invalid is_required argument \"$2\" in get_arg"
    ;;
  esac
  shift

  local option_arg="$1"
  shift

  unset out

  local get_next_arg
  for arg in "$@"; do
    if [ "${get_next_arg:-}" ]; then
      out="$arg"
      break
    # --foo=bar (get the value after '=')
    elif [ "${arg:0:$(( ${#option_arg} + 1 ))}" == "$option_arg=" ]; then
      out="${arg:$(( ${#option_arg} + 1 ))}"
      break
    # --foo bar (get the next argument)
    elif [ "$arg" == "$option_arg" ]; then
      get_next_arg=true
    fi
  done

  if [[ ! "${out:-}" && $is_required == true ]]; then
    die "Argument $option_arg is required, but was not found"
  fi
}
