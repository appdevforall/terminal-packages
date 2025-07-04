#!/usr/bin/env bash

#
# Copyright (C) 2025 Akash Yadav
# 
# This file is part of The Scribe Project.
#
# Scribe is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Scribe is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Scribe.  If not, see <https://www.gnu.org/licenses/>.
#

RED="\033[0;31m"
GREEN="\033[0;32m"
NC="\033[0m"

scribe_ok() {
  printf "${GREEN}%s${NC}\n" "$1"
}

scribe_error() {
  printf "${RED}%s${NC}\n" "$1"
}

scribe_error_exit() {
  scribe_error "$1"
  exit 1
}

scribe_check_command() {
  if [[ -z "$1" ]]; then
    scribe_error "Usage: $0 <command>"
    exit 1
  fi

  if ! [[ "$(command -v "$1")" ]]; then
    err "'$1' command is not available in PATH. Please install $1."
    exit 1
  fi
}
