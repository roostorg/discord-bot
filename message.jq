# Builds a Discord webhook message from a GitHub event payload, or outputs
# nothing if the event should be skipped. Usage:
#   jq --arg event "$GITHUB_EVENT_NAME" --from-file message.jq "$GITHUB_EVENT_PATH"

def truncate($n): if length > $n then .[:$n - 1] + "…" else . end;
def clean: (. // "") | gsub("\r"; "") | gsub("<!--[\\s\\S]*?-->"; "") | gsub("\n{3,}"; "\n\n") | gsub("^\\s+|\\s+$"; "");
# Discord rejects webhook names containing these, so fall back to the webhook default
def sender($user): {avatar_url: $user.avatar_url}
  + if $user.login | test("discord|clyde"; "i") then {} else {username: "@\($user.login) • GitHub"} end;
def message($title; $suffix; $item; $user; $length; $color): sender($user) + {
  embeds: [{
    title: ("\($title | truncate(200)) • \($suffix)"),
    url: $item.html_url,
    description: ($item.body | clean | truncate($length)),
    color: $color
  } | if .description == "" then del(.description) else . end],
  allowed_mentions: {parse: []}
};

# Colors from GitHub's palette: open green, in-progress yellow, and release blue
if $event == "issues" then
  message(.issue.title; "#\(.issue.number) (Issue)"; .issue; .issue.user; 500; 2066493)
elif $event == "pull_request_target" or $event == "pull_request" then
  if .pull_request.draft or .pull_request.user.type == "Bot" then empty
  else message(.pull_request.title; "#\(.pull_request.number) (PR)"; .pull_request; .pull_request.user; 500; 10118912) end
elif $event == "release" then
  (.release.name // "" | if . == "" then null else . end) as $name
  | message($name // .release.tag_name;
      ((if $name != null and $name != .release.tag_name then "\(.release.tag_name) " else "" end)
        + (if .release.prerelease then "(Pre-release)" else "(Release)" end));
      .release; .release.author; 2000; 616922)
else error("Unsupported event: \($event)") end
