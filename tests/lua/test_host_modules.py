from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).parents[2]


def run_lua(body: str) -> str:
    script = (
        f"local root = {json.dumps(str(ROOT / 'reaper') + '/')}\n"
        f"{body}"
    )
    result = subprocess.run(
        ["lua", "-"], input=script, text=True, capture_output=True, check=False
    )
    assert result.returncode == 0, result.stderr
    return result.stdout.strip()


def test_track_bindings_are_scoped_by_app_and_role_and_clear_stale_guids():
    run_lua(
        """
local json = dofile(root .. "json.lua")
local ext = {}
local track_list = {
  { guid = "selected", name = "Selected" },
  { guid = "fallback", name = "MMG Drums" },
}
local selected = track_list[1]
reaper = {}
function reaper.GetProjExtState(_, section, key)
  return 1, ext[section .. ":" .. key] or ""
end
function reaper.SetProjExtState(_, section, key, value)
  ext[section .. ":" .. key] = value
end
function reaper.CountTracks() return #track_list end
function reaper.GetTrack(_, index) return track_list[index + 1] end
function reaper.GetTrackGUID(track) return track.guid end
function reaper.GetTrackName(track) return true, track.name end
function reaper.CountSelectedTracks() return selected and 1 or 0 end
function reaper.GetSelectedTrack() return selected end
function reaper.GetSetMediaTrackInfo_String(track, key, value, set)
  if set and key == "P_NAME" then track.name = value end
  return true, track.name
end
function reaper.InsertTrackAtIndex(index)
  table.insert(track_list, index + 1, { guid = "created", name = "" })
end
local tracks = dofile(root .. "rptk_tracks.lua")(json)
local _, explicit = tracks.capture("com.example.one", "drums", true)
assert(explicit.binding == "explicit")
local _, role_two = tracks.capture("com.example.one", "effects", true)
assert(role_two.binding == "explicit")
local _, app_two = tracks.resolve_bound("com.example.two", "drums", {
  name = "MMG Drums", role = "drums", create = "if_missing"
}, true)
assert(app_two.guid == "fallback" and app_two.binding == "fallback")
track_list[1] = nil
local compact = {}
for _, value in pairs(track_list) do compact[#compact + 1] = value end
track_list = compact
local _, stale = tracks.resolve_bound("com.example.one", "drums", {
  name = "MMG Drums", role = "drums", create = "if_missing"
}, true)
assert(stale.guid == "fallback" and stale.binding == "fallback")
local _, still_separate = tracks.resolve_bound("com.example.two", "drums", {
  name = "unused", role = "drums", create = "never"
}, false)
assert(still_separate.guid == "fallback")
"""
    )


@pytest.mark.parametrize(
    ("numerator", "denominator", "bar_ppq"),
    [(4, 4, 3840), (3, 4, 2880), (6, 8, 2880), (7, 8, 3360)],
)
def test_preview_count_in_is_one_native_measure(numerator, denominator, bar_ppq):
    output = run_lua(
        f"""
local qn_per_measure = {numerator} * 4 / {denominator}
local measure_seconds = qn_per_measure * 0.5
reaper = {{}}
function reaper.TimeMap2_timeToBeats(_, seconds)
  return 0, math.floor(seconds / measure_seconds)
end
function reaper.TimeMap2_beatsToTime(_, _, measure)
  return measure * measure_seconds
end
local state = {{
  time_to_ppq = function(seconds) return math.floor(seconds / 0.5 * 960) end
}}
local preview = dofile(root .. "rptk_preview.lua")(state, {{}})
local exact_start, exact_origin = preview.measure_plan(0, true)
local mid_start, mid_origin = preview.measure_plan(measure_seconds / 2, true)
print(exact_start, exact_origin, mid_start, mid_origin)
"""
    )
    assert tuple(map(int, output.split())) == (0, bar_ppq, bar_ppq, bar_ppq * 2)


def test_atomic_insert_and_replace_keep_exact_resource_identity():
    run_lua(
        """
local json = dofile(root .. "json.lua")
local cursor = 0
local undo = {}
local target = { guid = "target", name = "Target", items = {}, depth = 0 }
local tracks_list = { target }
reaper = {}
function reaper.CountTracks() return #tracks_list end
function reaper.GetTrack(_, index) return tracks_list[index + 1] end
function reaper.GetTrackGUID(track) return track.guid end
function reaper.GetTrackName(track) return true, track.name end
function reaper.GetMediaTrackInfo_Value(track, key)
  if key == "IP_TRACKNUMBER" then
    for index, value in ipairs(tracks_list) do if value == track then return index end end
  end
  if key == "I_FOLDERDEPTH" then return track.depth end
  return 0
end
function reaper.GetSetMediaTrackInfo_String(track, key, value, set)
  track.ext = track.ext or {}
  if set then track.ext[key] = value end
  return true, track.ext[key] or ""
end
function reaper.CountTrackMediaItems(track) return #track.items end
function reaper.GetTrackMediaItem(track, index) return track.items[index + 1] end
function reaper.CreateNewMIDIItemInProj(track, start_time, end_time)
  local item = {
    position = start_time, length = end_time - start_time,
    take = { notes = {} }, ext = {},
  }
  table.insert(track.items, item)
  return item
end
function reaper.GetActiveTake(item) return item.take end
function reaper.MIDI_InsertNote(take, _, _, start_ppq, end_ppq)
  take.notes[#take.notes + 1] = { start_ppq, end_ppq }
end
function reaper.MIDI_Sort() end
function reaper.GetSetMediaItemInfo_String(item, key, value, set)
  if set then item.ext[key] = value end
  return true, item.ext[key] or ""
end
function reaper.GetMediaItemInfo_Value(item, key)
  if key == "D_POSITION" then return item.position end
  if key == "D_LENGTH" then return item.length end
  return 0
end
function reaper.DeleteTrackMediaItem(track, item)
  for index, value in ipairs(track.items) do
    if value == item then table.remove(track.items, index); return true end
  end
end
function reaper.ValidatePtr(item) return item ~= nil end
function reaper.GetCursorPosition() return cursor end
function reaper.SetEditCurPos(value) cursor = value end
function reaper.UpdateArrange() end
function reaper.Undo_BeginBlock2() undo[#undo + 1] = "begin" end
function reaper.Undo_EndBlock2(_, label) undo[#undo + 1] = label end
local state = {
  ppq = function() return 960 end,
  ppq_to_time = function(value) return value / 960 end,
  time_to_ppq = function(value) return math.floor(value * 960 + 0.5) end,
}
local tracks = {
  resolve_bound = function() return target, {} end,
  resolve = function() return target, {} end,
}
local items = dofile(root .. "rptk_midi_items.lua")(json, state, tracks)
local session = { id = "session", client = { app_id = "com.example.app" } }
local phrase = {
  source_ppqn = 960, length_ppq = 3840, revision = string.rep("a", 64),
  notes = {{ start_ppq = 0, duration_ppq = 120, channel = 9, pitch = 36, velocity = 100 }},
}
local inserted = items.insert(session, {
  track_ref = { role = "drums", name = "Target", create = "if_missing" },
  midi_phrase = phrase, metadata = { schema = 3 },
  options = { start_ppq = 3840, collision_policy = "layer",
    advance_cursor = "end", undo_label = "Insert" },
}, "midi_item")
assert(inserted.start_ppq == 3840 and inserted.length_ppq == 3840)
assert(cursor == 8)
assert(inserted.target_guid == "target" and inserted.track_guid == "target")
local full = items.public_state("com.example.app")
local lightweight = items.public_state("com.example.app", nil, nil, false)
assert(full[1].metadata.schema == 3)
assert(lightweight[1].metadata == nil)
assert(lightweight[1].resource_id == inserted.resource_id)
local id = inserted.resource_id
phrase.revision = string.rep("b", 64)
local replaced = items.replace(session, {
  resource_id = id, midi_phrase = phrase, metadata = { schema = 3 },
  options = { advance_cursor = "start", undo_label = "Replace" },
})
assert(replaced.resource_id == id and replaced.start_ppq == 3840)
assert(cursor == 4 and #target.items == 1)
assert(undo[2] == "Insert" and undo[4] == "Replace")
"""
    )


def test_udp_cleanup_sends_note_offs_only_for_the_owned_session():
    run_lua(
        """
local sent = {}
local one = { active_notes = { ["9:36"] = true }, udp_queue = { 1 } }
local two = { active_notes = { ["9:38"] = true }, udp_queue = { 2 } }
reaper = {
  StuffMIDIMessage = function(_, status, pitch, velocity)
    sent[#sent + 1] = { status, pitch, velocity }
  end
}
local sessions = { active = { one = one, two = two } }
local udp = dofile(root .. "rptk_udp.lua")(sessions)
udp.cleanup_session(one)
assert(#sent == 1 and sent[1][2] == 36)
assert(next(one.active_notes) == nil and #one.udp_queue == 0)
assert(two.active_notes["9:38"] == true and #two.udp_queue == 1)
"""
    )


def test_preview_tick_does_not_rewrite_unchanged_item_length():
    run_lua(
        """
local length_writes = 0
local item = { position = 0, length = 256, alive = true }
local resource = {
  resource_id = "preview", item = item, session_id = "session",
  length_ppq = 3840,
}
reaper = {
  ValidatePtr = function(value) return value and value.alive end,
  GetMediaItemInfo_Value = function(value, key)
    if key == "D_POSITION" then return value.position end
    if key == "D_LENGTH" then return value.length end
    return 0
  end,
  SetMediaItemInfo_Value = function(value, key, amount)
    if key == "D_LENGTH" then
      length_writes = length_writes + 1
      value.length = amount
    end
  end,
  GetPlayState = function() return 1 end,
  GetPlayPosition = function() return 1 end,
  SetProjExtState = function() end,
  GetSetRepeat = function() return 0 end,
  UpdateArrange = function() end,
}
local state = {
  time_to_ppq = function(seconds) return seconds * 960 end,
  ppq_to_time = function(ppq) return ppq / 960 end,
}
local items = {
  delete = function() end,
  adopt_id = function(value) return value end,
}
local preview = dofile(root .. "rptk_preview.lua")(state, items)
preview.active.preview = {
  id = "preview", resource = resource, origin = 0, phrase_length = 3840,
  status = "playing", prepared_at = 0,
}
preview.tick(1)
preview.tick(1.01)
assert(length_writes == 0)
"""
    )


def test_preview_stop_halts_transport_before_deleting_items():
    run_lua(
        """
local actions = {}
local active = {
  resource_id = "preview", session_id = "session", item = {},
}
local pending = {
  resource_id = "pending", session_id = "session", item = {},
}
reaper = {
  GetPlayState = function() return 1 end,
  OnStopButton = function() actions[#actions + 1] = "stop" end,
  SetProjExtState = function() end,
  GetSetRepeat = function() return 0 end,
}
local state = {}
local items = {
  delete = function(resource)
    actions[#actions + 1] = "delete:" .. resource.resource_id
  end,
}
local preview = dofile(root .. "rptk_preview.lua")(state, items)
preview.owner = "session"
preview.active.preview = {
  id = "preview", resource = active, pending = pending,
  active_revision = "revision",
}
local result = preview.stop({ id = "session" }, "preview")
assert(result.active == false)
assert(actions[1] == "stop")
assert(#actions == 1)
preview.tick(1)
preview.tick(2)
assert(actions[2] == "delete:preview")
assert(actions[3] == "delete:pending")
"""
    )


def test_preview_session_cleanup_does_not_stop_global_transport():
    run_lua(
        """
local stopped = 0
local deleted = 0
local resource = {
  resource_id = "preview", session_id = "session", item = {},
}
reaper = {
  GetPlayState = function() return 1 end,
  OnStopButton = function() stopped = stopped + 1 end,
  SetProjExtState = function() end,
  GetSetRepeat = function() return 0 end,
}
local state = {}
local items = {
  delete = function() deleted = deleted + 1 end,
}
local preview = dofile(root .. "rptk_preview.lua")(state, items)
preview.owner = "session"
preview.active.preview = {
  id = "preview", resource = resource, active_revision = "revision",
}
preview.cleanup_session({ id = "session" })
assert(stopped == 0)
assert(preview.active.preview == nil)
assert(deleted == 1)
"""
    )


def test_preview_tick_ignores_transport_jitter_and_forward_catchup():
    run_lua(
        """
local deleted = 0
local play_position = 10
local item = { position = 0, length = 256, alive = true }
local resource = {
  resource_id = "preview", item = item, session_id = "session",
  length_ppq = 3840,
}
reaper = {
  ValidatePtr = function(value) return value and value.alive end,
  GetMediaItemInfo_Value = function(value, key)
    if key == "D_POSITION" then return value.position end
    if key == "D_LENGTH" then return value.length end
    return 0
  end,
  SetMediaItemInfo_Value = function() end,
  GetPlayState = function() return 1 end,
  GetPlayPosition = function() return play_position end,
  SetProjExtState = function() end,
  GetSetRepeat = function() return 0 end,
}
local state = {
  time_to_ppq = function(seconds) return seconds * 960 end,
  ppq_to_time = function(ppq) return ppq / 960 end,
}
local items = {
  delete = function() deleted = deleted + 1 end,
  adopt_id = function(value) return value end,
}
local preview = dofile(root .. "rptk_preview.lua")(state, items)
preview.active.preview = {
  id = "preview", resource = resource, origin = 0, phrase_length = 3840,
  status = "playing", prepared_at = 0,
}
preview.tick(1)
play_position = 9.8
preview.tick(1.1)
assert(preview.active.preview ~= nil and deleted == 0)
play_position = 20
preview.tick(4)
assert(preview.active.preview ~= nil and deleted == 0)
play_position = 19
preview.tick(4.1)
assert(preview.active.preview == nil and deleted == 1)
"""
    )


def test_sessions_reclaim_orphan_and_extend_active_preview_lease():
    run_lua(
        """
local sessions = dofile(root .. "rptk_sessions.lua")({})
local identity = {
  app_id = "com.example.app", instance_id = "instance", display_name = "App",
}
local session = assert(sessions.create(identity, "socket-one", 10))
assert(session.lease_deadline == 15)
sessions.touch(session, 11, true)
assert(session.lease_deadline == 41)
sessions.detach(session, 12, true)
assert(session.attached == false and session.lease_deadline == 42)
local reclaimed, err, was_reclaimed =
  sessions.create(identity, "socket-two", 13)
assert(err == nil and was_reclaimed == true)
assert(reclaimed == session)
assert(reclaimed.id == session.id and reclaimed.udp_token == session.udp_token)
assert(reclaimed.attached == true and reclaimed.socket == "socket-two")
local duplicate, duplicate_err = sessions.create(identity, "socket-three", 14)
assert(duplicate == nil and duplicate_err == "duplicate_instance")
"""
    )
