#!/bin/sh
# ssh calls this instead of asking on a terminal; the password comes from the parent environment.
printf '%s\n' "$SMOLDER_UNLOCK_PW"
