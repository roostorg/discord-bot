# Builds a Discord webhook message from each GitHub event payload in the input,
# or outputs nothing for events that should be skipped. Usage:
#   jq --compact-output --arg event "$GITHUB_EVENT_NAME" --from-file message.jq "$GITHUB_EVENT_PATH"

# Colors from GitHub's palette
def green: 2066493;    # #1f883d, issues
def yellow: 10118912;  # #9a6700, pull requests
def blue: 616922;      # #0969da, releases
def red: 13706287;     # #d1242f, security advisories
def purple: 8540383;   # #8250df, discussions

# Discord message components: https://docs.discord.com/developers/components/reference
def is_components_v2: 32768;  # message flag, 1 << 15
def container: 17;
def text_display: 10;

def truncate($n):
  if length > $n then .[:$n - 1] + "…" else . end;

def clean:
  (. // "")
  | gsub("\r"; "")
  | gsub("<!--[\\s\\S]*?-->"; "")  # HTML comments, e.g. from templates
  | gsub("<picture\\b[\\s\\S]*?</picture>"; "🖼️"; "i") # picture tags
  | gsub("<img\\b[^>]*>"; "🖼️"; "i") # img tags
  | gsub("!\\[[^\\]]*\\]\\([^)]*\\)"; "🖼️") # Markdown images
  | gsub("\n{3,}"; "\n\n")
  | gsub("^\\s+|\\s+$"; "");

# Backslash-escapes \ * _ ~ ` | [ ] < > @. Discord ignores escapes inside link
# text, so this is only for titles outside a link.
def escape_markdown:
  gsub("(?<c>[\\\\*_~`|\\[\\]<>@])"; "\\\(.c)");

# Removes innermost [pairs] until none are left, then checks for a stray [
def has_unclosed_bracket:
  if test("\\[[^\\[\\]]*\\]") then gsub("\\[[^\\[\\]]*\\]"; "") | has_unclosed_bracket
  else test("\\[") end;

# Discord refuses to link text containing URLs, mass or raw mentions, or an unclosed [
def linkable:
  (test("://|@everyone|@here|<[@#]") or has_unclosed_bracket) | not;

# "### [Title • #1 (PR)](url)", or "### Title • [#1 (PR)](url)" if the title can't be linked
def heading($title; $suffix; $url):
  if $title | linkable
  then "### [\($title) • \($suffix)](\($url))"
  else "### \($title | escape_markdown) • [\($suffix)](\($url))"
  end;

# Discord rejects webhook names containing these, so fall back to the webhook default
def sender($user):
  if $user == null then {}
  elif $user.login | test("discord|clyde"; "i") then {avatar_url: $user.avatar_url}
  else {avatar_url: $user.avatar_url, username: "@\($user.login) • GitHub"}
  end;

# Takes {title, suffix, url, body, body_length, user, color}. Uses components
# instead of embeds so posts still show for people with embeds turned off.
def message:
  . as $m
  | ($m.body | clean | truncate($m.body_length)) as $body
  | sender($m.user) + {
      flags: is_components_v2,
      components: [{
        type: container,
        accent_color: $m.color,
        components: [{
          type: text_display,
          content: (heading($m.title | truncate(200); $m.suffix; $m.url)
            + if $body == "" then "" else "\n\($body)" end)
        }]
      }],
      allowed_mentions: {parse: []}
    };

def issue_message:
  .issue
  | {title, url: .html_url, body, user,
     suffix: "#\(.number) (Issue)", body_length: 500, color: green}
  | message;

def pull_request_message:
  .pull_request
  | if .draft or .user.type == "Bot" then empty
    else
      {title, url: .html_url, body, user,
       suffix: "#\(.number) (PR)", body_length: 500, color: yellow}
      | message
    end;

# Labeled by category, e.g. "#12 (Q&A)"
def discussion_message:
  .discussion
  | if .user.type == "Bot" then empty
    else
      {title, url: .html_url, body, user,
       suffix: "#\(.number) (\(.category.name // "Discussion"))", body_length: 500, color: purple}
      | message
    end;

# Titled by the release name, or the tag if unnamed; shows the tag too if they differ
def release_message:
  .release
  | (if .name == null or .name == "" then .tag_name else .name end) as $title
  | (if .prerelease then "(Pre-release)" else "(Release)" end) as $kind
  | {title: $title, url: .html_url, body, user: .author,
     suffix: (if $title == .tag_name then $kind else "\(.tag_name) \($kind)" end),
     body_length: 2000, color: blue}
  | message;

# Advisories may be unpublished: post only the ID, state, severity, and link,
# never the title, description, affected code, or reporter. Only known states
# and severities are shown.
def repository_advisory_message:
  def capitalize: (.[:1] | ascii_upcase) + .[1:];
  .repository_advisory
  | (if .severity | IN("critical", "high", "medium", "low")
     then "\(.severity | capitalize) severity" else "Unknown severity" end) as $severity
  | (if .state | IN("triage", "draft", "published", "closed", "withdrawn")
     then "\(.state | capitalize) advisory" else "Advisory" end) as $state
  | {title: .ghsa_id, url: .html_url, body: null, user: null,
     suffix: "\($severity) (\($state))", body_length: 0, color: red}
  | message;

if $event == "issues" then issue_message
elif $event | IN("pull_request_target", "pull_request") then pull_request_message
elif $event == "discussion" then discussion_message
elif $event == "release" then release_message
elif $event == "repository_advisory" then repository_advisory_message
else error("Unsupported event: \($event)")
end
