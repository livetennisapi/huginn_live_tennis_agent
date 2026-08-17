# huginn_live_tennis_agent

A [Huginn](https://github.com/huginn/huginn) agent for the
[Live Tennis API](https://livetennisapi.com).

> **Disclosure:** we run the Live Tennis API — this agent gem is
> vendor-authored and maintained by the API's own team.

`Agents::LiveTennisAgent` polls the API on Huginn's scheduler and emits events
only on **state transitions**, diffing each check against the agent's memory:

| Mode | Event | When |
|---|---|---|
| `live_scores` | `match_started` | a match appears on the live board |
| `live_scores` | `score_changed` | a tracked match's score moves (with `break_point` derivation) |
| `live_scores` | `match_finished` | a tracked match leaves the live board (optionally confirmed with the final winner) |
| `fixtures` | `new_fixture` | a scheduled fixture appears |
| `fixtures` | `fixture_updated` | the order of play assigns/changes a fixture's start time |

It uses **FREE-tier endpoints only**: `GET /matches?status=live`,
`GET /matches/{id}` and `GET /fixtures`.

## Getting a key, and tier honesty

The FREE keyed tier (no card) is at <https://livetennisapi.com/subscribe/free>:
**30 requests/minute, 100 requests/day**, covering live scores
(score / server / break-point state), players (including current ranking),
fixtures, the tournament catalogue and your own usage stats.

**Polling cadence:** 100 requests/day supports develop-and-test or
roughly-15-minute-or-slower checks — *not* continuous fast polling. The
agent's default schedule is `every_30m` (≈48 checks/day), which leaves
headroom for the one-per-finished-match confirmation lookups. We recommend
`every_30m` or slower on a FREE key; if you schedule `every_10m` (≈144/day)
or faster you will hit the daily cap partway through the day. Paid tiers
raise the limits: Basic $9.99 (60/min, 1,000/day), Pro $29.99 (300/min,
10,000/day), Ultra $99.99 (600/min, 500,000/day — including a WebSocket live
feed that makes polling unnecessary altogether). Full docs:
<https://docs.livetennisapi.com>.

## Installation

This gem runs inside [Huginn](https://github.com/huginn/huginn). It is not on
RubyGems yet (**rubygems publish pending**), but Huginn's `ADDITIONAL_GEMS`
supports git references, so it installs directly from this repository today.

Add to your Huginn `.env`:

```bash
ADDITIONAL_GEMS=huginn_live_tennis_agent(github: livetennisapi/huginn_live_tennis_agent)
```

(If you already have other additional gems, append with a comma:
`ADDITIONAL_GEMS=other_agent_gem,huginn_live_tennis_agent(github: livetennisapi/huginn_live_tennis_agent)`.)

Then, from your Huginn root:

```bash
bundle
```

and restart Huginn. `LiveTennisAgent` appears in the agent type list.

Once the RubyGems release is out, the line shrinks to
`ADDITIONAL_GEMS=huginn_live_tennis_agent`.

## Configuration

Store your key as a Huginn credential named `live_tennis_api_key`
(Credentials → New Credential), then reference it from the agent options —
never paste a key into agent options directly:

```json
{
  "api_key": "{% credential live_tennis_api_key %}",
  "mode": "live_scores",
  "tour": "",
  "lookup_finished": "true"
}
```

| Option | Values | Notes |
|---|---|---|
| `api_key` | credential reference | required |
| `mode` | `live_scores` (default), `fixtures` | |
| `tour` | `atp`, `wta`, `challenger`, `itf`, `juniors`, or blank | blank = all tours |
| `lookup_finished` | `true` (default) / `false` | `live_scores` only: confirm each finished match with one extra FREE `GET /matches/{id}` request, adding `winner`, `status`, `event_status` and `final_score` to the event |

**First-check priming:** the very first check fills the agent's memory and
emits nothing, so enabling the agent mid-tournament does not flood your
scenario with stale `match_started` events. Transitions are emitted from the
second check onward.

## Event payloads

### `match_started`

```json
{
  "event_type": "match_started",
  "match": {
    "id": 12345,
    "tournament": "Cincinnati Open",
    "tour": "atp",
    "surface": "hard",
    "status": "live",
    "players": { "p1": { "id": 1, "name": "Player One" }, "p2": { "id": 2, "name": "Player Two" } },
    "score": { "sets": [0, 0], "games": [[0], [0]], "points": ["0", "0"], "server": 1, "is_tiebreak": false }
  }
}
```

`match` is the API's match object verbatim
([schema](https://github.com/livetennisapi/openapi)).

### `score_changed`

```json
{
  "event_type": "score_changed",
  "match_id": 12345,
  "tournament": "Cincinnati Open",
  "tour": "atp",
  "players": { "p1": "Player One", "p2": "Player Two" },
  "score": { "sets": [1, 0], "games": [[6, 2], [4, 1]], "points": ["30", "40"], "server": 1, "is_tiebreak": false },
  "previous_score": { "sets": [1, 0], "games": [[6, 2], [4, 1]], "points": ["30", "30"], "server": 1, "is_tiebreak": false },
  "break_point": true
}
```

`break_point` is derived from the score: **receiver at `AD`, or receiver at
`40` while the server is at `0`/`15`/`30`**. It is never set during tiebreaks,
and it is `null` (unknown, not false) whenever `server` or a point entry is
null. The score fingerprint ignores `timestamp`, so a re-stamped identical
score does not emit.

### `match_finished`

```json
{
  "event_type": "match_finished",
  "match_id": 12345,
  "tournament": "Cincinnati Open",
  "tour": "atp",
  "players": { "p1": "Player One", "p2": "Player Two" },
  "last_known_score": { "sets": [1, 1], "games": [[6, 2, 5], [4, 6, 5]], "points": ["40", "30"], "server": 1, "is_tiebreak": false },
  "confirmed": true,
  "status": "completed",
  "winner": 1,
  "event_status": null,
  "final_score": { "sets": [2, 1], "games": [[6, 2, 7], [4, 6, 5]], "points": [null, null], "server": null, "is_tiebreak": false }
}
```

With `lookup_finished: false` — or when the confirming request fails — the
event ends at `"confirmed": false` (no `status`/`winner`/`event_status`/
`final_score`). "Finished" means *left the live board*: with confirmation on,
`status` distinguishes `completed` from `cancelled`, and `event_status`
surfaces retirements and walkovers (`winner` stays per the API's rules). A
match the lookup still reports as `live` (a transient list gap, e.g. a rain
interruption) is silently kept under tracking; one reported back as
`upcoming` (postponed) is dropped silently and will emit `match_started`
when it actually starts.

### `new_fixture` / `fixture_updated`

```json
{
  "event_type": "fixture_updated",
  "fixture": {
    "id": 678,
    "event_date": "2026-08-18",
    "start_time": "2026-08-18T14:30:00Z",
    "tournament": "Cincinnati Open",
    "tour": "atp",
    "round": "R16",
    "player1_name": "Player One",
    "player2_name": "Player Two"
  },
  "previous_start_time": null
}
```

A null `start_time` is a real state (the order of play hasn't assigned a time
yet), so the null→time transition is exactly what `fixture_updated` exists
for.

## Example scenario

A minimal scenario JSON you can import (Scenarios → Import): polls live ATP
scores every 30 minutes and pushes each transition through a formatting agent
you can point at any notifier.

```json
{
  "schema_version": 1,
  "name": "Live tennis transitions",
  "description": "Emits match_started / score_changed / match_finished events from the Live Tennis API (FREE tier, every_30m).",
  "guid": "live-tennis-transitions-example",
  "tag_fg_color": "#ffffff",
  "tag_bg_color": "#175e2a",
  "exported_at": "2026-08-17T12:00:00Z",
  "agents": [
    {
      "type": "Agents::LiveTennisAgent",
      "name": "Live tennis scores",
      "disabled": false,
      "guid": "live-tennis-source",
      "options": {
        "api_key": "{% credential live_tennis_api_key %}",
        "mode": "live_scores",
        "tour": "atp",
        "lookup_finished": "true"
      },
      "schedule": "every_30m",
      "keep_events_for": 604800
    },
    {
      "type": "Agents::EventFormattingAgent",
      "name": "Format tennis transition",
      "disabled": false,
      "guid": "live-tennis-format",
      "options": {
        "instructions": {
          "message": "{{ event_type }}: {{ players.p1 }} vs {{ players.p2 }} ({{ tournament }})"
        },
        "mode": "clean"
      },
      "keep_events_for": 604800
    }
  ],
  "links": [
    { "source": 0, "receiver": 1 }
  ],
  "control_links": []
}
```

Import requires the gem to be installed first (otherwise Huginn won't know
`Agents::LiveTennisAgent`). Remember to create the `live_tennis_api_key`
credential.

## Development

```bash
bundle install
bundle exec rspec
```

The specs run standalone against a lightweight Huginn `Agent` shim
(`spec/support/huginn_agent_shim.rb`) with all HTTP stubbed via WebMock — no
Huginn checkout or database needed. The gem also loads cleanly under the
standard [huginn_agent](https://github.com/huginn/huginn_agent) integration
harness; see the note in the `Rakefile` if you want to run it inside a full
Huginn clone.

## License

[MIT](LICENSE.txt).
