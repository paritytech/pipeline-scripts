die() {
  if [ "${1:-}" ]; then
    >&2 echo "$1"
  fi
  exit 1
}

get_arg() {
  local arg_type="$1"
  shift

  local is_required
  case "$arg_type" in
    required|required-multi)
      is_required=true
    ;;
    optional|optional-multi) ;;
    *)
      die "Invalid is_required argument \"$2\" in get_arg"
    ;;
  esac

  local is_multi
  if [ "${arg_type: -6}" == "-multi" ]; then
    is_multi=true
  fi

  local option_arg="$1"
  shift

  unset out
  out=()

  local get_next_arg
  for arg in "$@"; do
    if [ "${get_next_arg:-}" ]; then
      out+=("$arg")
      if [ ! "${is_multi:-}" ]; then
        break
      fi
      unset get_next_arg
    # --foo=bar (get the value after '=')
    elif [ "${arg:0:$(( ${#option_arg} + 1 ))}" == "$option_arg=" ]; then
      out+=("${arg:$(( ${#option_arg} + 1 ))}")
      if [ ! "${is_multi:-}" ]; then
        break
      fi
    # --foo bar (get the next argument)
    elif [ "$arg" == "$option_arg" ]; then
      get_next_arg=true
    fi
  done

  if [ "${out[0]:-}" ]; then
    if [ ! "${is_multi:-}" ]; then
      out="${out[0]}"
    fi
  elif [ "${is_required:-}" ]; then
    die "Argument $option_arg is required, but was not found"
  else
    unset out
  fi
}
