#!/usr/bin/env bats
@test "main prints the project name" {
  run bash src/main.sh
  [ "${status}" -eq 0 ]
}
