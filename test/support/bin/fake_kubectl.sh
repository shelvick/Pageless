#!/usr/bin/env sh
set -eu

stdout=""
stderr=""
exit_code=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --exit-with)
      shift
      exit_code="$1"
      ;;
    --print-stdout)
      shift
      stdout="$1"
      ;;
    --print-stderr)
      shift
      stderr="$1"
      ;;
    --echo-env)
      shift
      eval "env_value=\${$1:-}"
      stdout="$stdout$env_value"
      ;;
  esac
  shift
done

if [ -n "$stdout" ]; then
  printf '%s\n' "$stdout"
fi

if [ -n "$stderr" ]; then
  printf '%s\n' "$stderr" >&2
fi

exit "$exit_code"
