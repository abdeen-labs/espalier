#!/bin/zsh
# Espalier's command line tool (desktop's app/static/darwin/github.sh and
# app/src/cli/main.ts). Espalier ▸ Install Command Line Tool… links it at
# /usr/local/bin/espalier; it opens the Espalier it's part of.
#
#   espalier                            Open the current folder in Espalier
#   espalier open [path]                Open a folder in Espalier
#   espalier clone [-b branch] <url>    Clone a repository by URL or
#                                       owner/name, optionally checking out a
#                                       branch
#
# A folder opens as if it were dropped on Espalier's Dock icon. A clone opens
# an espalier://openRepo link, which selects the repository when it's already
# in Espalier and offers to clone it otherwise.
#
# Options go anywhere, as desktop's (minimist): -b <branch>, -b<branch>,
# --branch <branch>, --branch=<branch>, and -h or --help; `--` ends them.
# With ESPALIER_CLI_DRY_RUN set, the `open` command is printed, one argument
# per line, instead of run (for tests).

emulate -L zsh
setopt no_unset

usage() {
  print -u2 "Usage:"
  print -u2 "  espalier                            Open the current folder in Espalier"
  print -u2 "  espalier open [path]                Open a folder in Espalier"
  print -u2 "  espalier clone [-b branch] <url>    Clone a repository by URL or owner/name"
  print -u2 "                                      (for example torvalds/linux), optionally"
  print -u2 "                                      checking out a branch"
  exit ${1:-1}
}

# Percent-encodes a URL query value, byte by byte.
encode() {
  local LC_ALL=C value=$1 encoded='' char
  local -i index
  for (( index = 1; index <= ${#value}; index++ )); do
    char=${value[index]}
    case $char in
      ([A-Za-z0-9._~-]) encoded+=$char ;;
      (*) encoded+=$(printf '%%%02X' "'$char") ;;
    esac
  done
  print -r -- $encoded
}

# Runs `open` with the arguments, or prints them for a dry run.
run_open() {
  if [[ -n ${ESPALIER_CLI_DRY_RUN-} ]]; then
    print -rl -- open "$@"
    exit 0
  fi
  exec open "$@"
}

# The app bundle: this script is <bundle>/Contents/Resources/espalier.sh.
app=${${0:A}:h:h:h}

# Options anywhere; everything else is a word, in order.
branch=''
help=0
words=()
while (( $# )); do
  case $1 in
    (-h|--help) help=1 ;;
    (-b|--branch)
      (( $# >= 2 )) || usage
      branch=$2
      shift
      ;;
    (--branch=*) branch=${1#--branch=} ;;
    (-b?*) branch=${1#-b} ;;
    (--)
      shift
      words+=("$@")
      break
      ;;
    (-?*)
      print -u2 "espalier: unknown option $1"
      usage
      ;;
    (*) words+=("$1") ;;
  esac
  shift
done
set -- "${words[@]}"

if (( help )); then
  usage 0
fi

case ${1-} in
  (help)
    usage 0
    ;;
  (clone)
    shift
    (( $# == 1 )) || usage
    url=$1
    # owner/name means GitHub.com.
    if [[ $url =~ '^[^/]+/[^/]+$' ]]; then
      url="https://github.com/$url"
    fi
    link="espalier://openRepo/$url"
    if [[ -n $branch ]]; then
      link+="?branch=$(encode $branch)"
    fi
    run_open -a $app $link
    ;;
  (open)
    shift
    (( $# <= 1 )) || usage
    folder=${1:-.}
    ;;
  (*)
    (( $# <= 1 )) || usage
    folder=${1:-.}
    ;;
esac

if [[ ! -d $folder ]]; then
  print -u2 "espalier: $folder is not a folder"
  exit 1
fi
run_open -a $app ${folder:A}
