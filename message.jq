# Builds a Discord webhook message from each GitHub event payload in the input,
# or outputs nothing for events that should be skipped. Usage:
#   jq --compact-output --arg event "$GITHUB_EVENT_NAME" --from-file message.jq "$GITHUB_EVENT_PATH"

def truncate($n): if length > $n then .[:$n - 1] + "…" else . end;
def clean: (. // "") | gsub("\r"; "") | gsub("<!--[\\s\\S]*?-->"; "") | gsub("\n{3,}"; "\n\n") | gsub("^\\s+|\\s+$"; "");
# Keep titles literal inside the markdown link
def escape: gsub("(?<c>[\\\\*_~`|\\[\\]<>])"; "\\\(.c)");
# Discord rejects webhook names containing these, so fall back to the webhook default
def sender($user): if $user == null then {} else {avatar_url: $user.avatar_url}
  + if $user.login | test("discord|clyde"; "i") then {} else {username: "@\($user.login) • GitHub"} end end;
# Components instead of embeds so posts still show for people with embeds turned off
def message($title; $suffix; $item; $user; $length; $color):
  ($item.body | clean | truncate($length)) as $body
  | sender($user) + {
    flags: 32768,
    components: [{
      type: 17,
      accent_color: $color,
      components: [{
        type: 10,
        content: ("### [\($title | truncate(200) | escape) • \($suffix)](\($item.html_url))"
          + if $body == "" then "" else "\n\($body)" end)
      }]
    }],
    allowed_mentions: {parse: []}
  };

def capitalize: (.[:1] | ascii_upcase) + .[1:];

# Colors from GitHub's palette: open green, in-progress yellow, release blue, and danger red
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
elif $event == "repository_advisory" then
  # Advisories may be unpublished: post only the ID, state, severity and link,
  # never the title, description, affected code or reporter.
  .repository_advisory
  | (if .severity == "critical" or .severity == "high" or .severity == "medium" or .severity == "low"
      then "\(.severity | capitalize) severity" else "Unknown severity" end) as $severity
  | (if .state == "triage" or .state == "draft" or .state == "published" or .state == "closed" or .state == "withdrawn"
      then "\(.state | capitalize) advisory" else "Advisory" end) as $state
  | message(.ghsa_id; "\($severity) (\($state))"; {html_url: .html_url}; null; 0; 13706287)
else error("Unsupported event: \($event)") end
