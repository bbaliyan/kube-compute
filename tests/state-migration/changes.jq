# One line per resource that the plan changes or moves: "<kind> <address>".
# kind is move, update, create, delete or replace. A move that also changes the
# resource prints both lines. Data source reads are left out.
.resource_changes[]
| select(.mode == "managed")
| (.change.actions | sort) as $actions
| (if .previous_address then "move \(.previous_address) -> \(.address)" else empty end),
  (if $actions == ["no-op"] then empty
   elif $actions == ["update"] then "update \(.address)"
   elif $actions == ["create"] then "create \(.address)"
   elif $actions == ["delete"] then "delete \(.address)"
   else "replace \(.address)" end)
