// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Every direct colour tmm draws in. The first half names each colour for
//! what it looks like; the second gives each one its job, and the drawing
//! code only ever asks for the job. Status symbols and the dim footer use the
//! terminal's own palette instead, so they follow its theme.

pub const RGB = [3]u8;

// The colours.

pub const hot_pink: RGB = .{ 244, 55, 151 };
pub const violet: RGB = .{ 111, 85, 240 };
pub const orchid: RGB = .{ 174, 65, 209 };
pub const jade: RGB = .{ 49, 179, 144 };
pub const cornflower: RGB = .{ 92, 150, 245 };
pub const charcoal: RGB = .{ 30, 30, 34 };
pub const near_black: RGB = .{ 20, 21, 21 };
pub const white: RGB = .{ 255, 255, 255 };
pub const aquamarine: RGB = .{ 72, 214, 176 };
pub const deep_teal: RGB = .{ 58, 96, 90 };
pub const midnight_teal: RGB = .{ 20, 28, 33 };
pub const sage: RGB = .{ 150, 206, 128 };
pub const goldenrod: RGB = .{ 232, 198, 104 };
pub const terracotta: RGB = .{ 204, 122, 88 };
pub const steel_blue: RGB = .{ 120, 168, 186 };
pub const periwinkle: RGB = .{ 128, 150, 222 };
pub const lavender: RGB = .{ 176, 156, 210 };
pub const moss: RGB = .{ 150, 186, 120 };
pub const sand: RGB = .{ 196, 172, 118 };
pub const slate: RGB = .{ 176, 182, 200 };

// Their jobs.

/// The corners of the field the title, headings and session names are drawn
/// from: pink to violet along the top, purple to teal along the bottom.
pub const field_top_left = hot_pink;
pub const field_top_right = violet;
pub const field_bottom_left = orchid;
pub const field_bottom_right = jade;
/// What a faded colour fades toward: near the dark background the field is
/// drawn over.
pub const field_shade = charcoal;
/// What a lifted colour is lifted toward.
pub const field_lift = white;
/// The top of the cool ramp session names take, which runs down into the
/// field's bottom-right corner.
pub const session_name_top = cornflower;

/// The bar beside the selected session, a green-cyan no heading or name is
/// drawn in, and the bar beside the pointer's, the same green greyed and
/// dimmed.
pub const selected_bar = aquamarine;
pub const hover_bar = deep_teal;
/// The card behind the selected session, barely off the background.
pub const session_card = midnight_teal;
/// The background assumed until the terminal reports its own.
pub const assumed_background = near_black;

/// Server and display names, apart from the pink headings above them.
pub const entry_name = sage;
/// The blink mark, warm so it reads as something to press.
pub const blink_mark = goldenrod;

/// Process names: one per agent, muted so the status symbols stay the
/// loudest thing on a row, and a soft slate for everything else.
pub const claude_name = terracotta;
pub const codex_name = steel_blue;
pub const gemini_name = periwinkle;
pub const opencode_name = lavender;
pub const aider_name = moss;
pub const pi_name = sand;
pub const process_name = slate;
