//! Decent Sampler presets (`.dspreset`): `<groups>` of `<group>`s of
//! `<sample>`s, attributes inherited down that chain, `<tags>`, and
//! keyswitches as `<midi><note>` bindings that enable groups or tags (or
//! choose a `<ui>` menu's option that does). Effects, modulators and the
//! UI's look are not played.

use super::{FormatReader, extension_is, parse_key};
use crate::model::*;
use roxmltree::{Document, Node};
use std::path::Path;

pub struct DecentSampler;

impl FormatReader for DecentSampler {
    fn name(&self) -> &'static str {
        "dspreset"
    }

    fn detect(&self, path: &Path, head: &[u8]) -> bool {
        extension_is(path, "dspreset")
            || String::from_utf8_lossy(head).contains("<DecentSampler")
    }

    fn read(&self, path: &Path) -> Result<Instrument, String> {
        let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
        let doc = Document::parse(&text).map_err(|e| format!("{}: {e}", path.display()))?;
        let dir = path.parent().unwrap_or(Path::new("."));
        read_document(&doc, dir)
    }
}

/// A binding that turns a group or a tag on or off.
#[derive(Clone, Debug)]
enum Enable {
    Group(usize, bool),
    Tag(String, bool),
}

fn read_document(doc: &Document, dir: &Path) -> Result<Instrument, String> {
    let root = doc.root_element();
    if root.tag_name().name() != "DecentSampler" {
        return Err("not a Decent Sampler preset".into());
    }
    let mut inst = Instrument { curves: Curve::builtin(), ..Default::default() };
    let groups_node = child(root, "groups").ok_or("no <groups>")?;
    let groups: Vec<Node> = groups_node
        .children()
        .filter(|n| n.is_element() && n.tag_name().name() == "group")
        .collect();

    // Tags declared with their first state.
    let mut tag_enabled: Vec<(String, bool)> = Vec::new();
    let mut tag_polyphony: Vec<(String, u32)> = Vec::new();
    if let Some(tags) = child(root, "tags") {
        for tag in tags.children().filter(|n| n.has_tag_name("tag")) {
            let name = tag.attribute("name").unwrap_or("").to_string();
            tag_enabled.push((name.clone(), tag.attribute("enabled") != Some("false")));
            if let Some(p) = tag.attribute("polyphony").and_then(|p| p.parse::<i64>().ok())
                && p > 0
            {
                tag_polyphony.push((name, p as u32));
            }
        }
    }

    // Articulations: menu options in the UI, and keyswitch notes.
    let mut menu_options: Vec<(usize, Vec<(String, Vec<Enable>)>)> = Vec::new();
    if let Some(ui) = child(root, "ui") {
        for (position, control) in ui
            .descendants()
            .filter(|n| n.is_element() && n.parent().is_some_and(|p| p.has_tag_name("tab")))
            .enumerate()
        {
            if control.has_tag_name("menu") {
                let options = control
                    .children()
                    .filter(|n| n.has_tag_name("option"))
                    .map(|o| (o.attribute("name").unwrap_or("").to_string(), enables(o, &groups)))
                    .collect();
                menu_options.push((position, options));
            }
        }
    }
    let mut keyswitches: Vec<(u8, Vec<Enable>, bool)> = Vec::new();
    if let Some(midi) = child(root, "midi") {
        for note in midi.children().filter(|n| n.has_tag_name("note")) {
            if note.attribute("enabled") == Some("false")
                || note.attribute("eventType") == Some("note_off")
            {
                continue;
            }
            let Some(key) = note.attribute("note").and_then(parse_key) else { continue };
            let mut set = enables(note, &groups);
            // A keyswitch may choose a menu's option instead.
            for b in note.children().filter(|n| n.has_tag_name("binding")) {
                if b.attribute("level") == Some("ui") && b.attribute("parameter") == Some("VALUE") {
                    let position = b.attribute("position").and_then(|p| p.parse::<usize>().ok());
                    let value = b.attribute("translationValue").and_then(|v| v.parse::<usize>().ok());
                    if let (Some(p), Some(v)) = (position, value)
                        && let Some((_, options)) = menu_options.iter().find(|m| m.0 == p)
                        && let Some(option) = options.get(v.saturating_sub(1))
                    {
                        set.extend(option.1.iter().cloned());
                    }
                }
            }
            let swallow = note.attribute("swallowNotes") == Some("true");
            if !set.is_empty() && (0..128).contains(&key) {
                keyswitches.push((key as u8, set, swallow));
            }
        }
    }

    // Switch layers: every group and tag that something turns on or off.
    let mut layers: Vec<Enable> = Vec::new();
    let all_sets = keyswitches
        .iter()
        .map(|k| &k.1)
        .chain(menu_options.iter().flat_map(|m| m.1.iter().map(|o| &o.1)));
    for set in all_sets {
        for e in set {
            let known = layers.iter().any(|l| match (l, e) {
                (Enable::Group(a, _), Enable::Group(b, _)) => a == b,
                (Enable::Tag(a, _), Enable::Tag(b, _)) => a == b,
                _ => false,
            });
            if !known && layers.len() < 128 {
                layers.push(e.clone());
            }
        }
    }
    let layer_of_group = |g: usize| layers.iter().position(|l| matches!(l, Enable::Group(x, _) if *x == g));
    let layer_of_tag = |t: &str| layers.iter().position(|l| matches!(l, Enable::Tag(x, _) if x == t));
    let group_on = |g: usize| groups[g].attribute("enabled") != Some("false");
    let tag_on = |t: &str| tag_enabled.iter().find(|x| x.0 == t).is_none_or(|x| x.1);
    for (i, layer) in layers.iter().enumerate() {
        let on = match layer {
            Enable::Group(g, _) => group_on(*g),
            Enable::Tag(t, _) => tag_on(t),
        };
        if on {
            inst.default_switch |= 1 << i;
        }
    }
    let mask_values = |set: &[Enable]| {
        let (mut mask, mut values) = (0u128, 0u128);
        for e in set {
            let (layer, on) = match e {
                Enable::Group(g, on) => (layer_of_group(*g), *on),
                Enable::Tag(t, on) => (layer_of_tag(t), *on),
            };
            if let Some(l) = layer {
                mask |= 1 << l;
                if on {
                    values |= 1 << l;
                } else {
                    values &= !(1 << l);
                }
            }
        }
        (mask, values)
    };
    let name_of = |set: &[Enable]| {
        let names: Vec<String> = set
            .iter()
            .filter_map(|e| match e {
                Enable::Group(g, true) => groups[*g].attribute("name").map(str::to_string),
                Enable::Tag(t, true) => Some(t.clone()),
                _ => None,
            })
            .collect();
        (!names.is_empty()).then(|| names.join(" + "))
    };
    for (key, set, swallow) in &keyswitches {
        let (mask, values) = mask_values(set);
        inst.switches.push(Switch { key: *key, mask, values, swallow: *swallow });
        let name = name_of(set).unwrap_or_else(|| format!("Keyswitch {}", crate::m2::key_name(*key)));
        inst.articulations.push(Articulation {
            m2: crate::m2::code_for_name(&name),
            name,
            keyswitch: Some(*key),
            mask,
            values,
        });
    }
    // Menu options no keyswitch chooses are articulations too.
    for (_, options) in &menu_options {
        for (name, set) in options {
            let (mask, values) = mask_values(set);
            if mask == 0 || inst.articulations.iter().any(|a| a.mask == mask && a.values == values) {
                continue;
            }
            inst.articulations.push(Articulation {
                m2: crate::m2::code_for_name(name),
                name: name.clone(),
                keyswitch: None,
                mask,
                values,
            });
        }
    }
    inst.default_articulation = inst
        .articulations
        .iter()
        .position(|a| inst.default_switch & a.mask == a.values);

    // Choke tags as numbers.
    let mut tag_ids: Vec<String> = Vec::new();
    let mut tag_id = |t: &str| -> i64 {
        if let Some(i) = tag_ids.iter().position(|x| x == t) {
            return i as i64 + 1;
        }
        tag_ids.push(t.to_string());
        tag_ids.len() as i64
    };

    for (gi, group) in groups.iter().enumerate() {
        if !group_on(gi) && layer_of_group(gi).is_none() {
            continue;
        }
        let samples: Vec<Node> = group.children().filter(|n| n.has_tag_name("sample")).collect();
        // Round robin length found from the positions when not given.
        let auto_length = samples
            .iter()
            .filter_map(|s| s.attribute("seqPosition").and_then(|p| p.parse::<u32>().ok()))
            .max()
            .unwrap_or(1);
        for sample in samples {
            let get = |name: &str| {
                sample
                    .attribute(name)
                    .or_else(|| group.attribute(name))
                    .or_else(|| groups_node.attribute(name))
            };
            let num = |name: &str| get(name).and_then(|v| v.trim().parse::<f32>().ok());
            let Some(path) = sample.attribute("path") else {
                inst.warn("a <sample> without a path");
                continue;
            };
            let mut r = Region {
                source: Source::File(dir.join(path.replace('\\', "/"))),
                ..Region::default()
            };
            let key = |name: &str| get(name).and_then(parse_key).map(|k| k.clamp(0, 127) as u8);
            r.keycenter = key("rootNote");
            r.lokey = key("loNote").unwrap_or(0);
            r.hikey = key("hiNote").unwrap_or(127);
            r.lovel = num("loVel").map_or(1, |v| v.clamp(1.0, 127.0) as u8);
            r.hivel = num("hiVel").map_or(127, |v| v.clamp(0.0, 127.0) as u8);
            r.offset = num("start").map_or(0, |v| v.max(0.0) as u64);
            r.end = num("end").map(|v| v.max(0.0) as u64);
            r.tune = 100.0
                * (num("tuning").unwrap_or(0.0)
                    + group.attribute("groupTuning").and_then(|v| v.parse::<f32>().ok()).unwrap_or(0.0)
                    + groups_node.attribute("globalTuning").and_then(|v| v.parse::<f32>().ok()).unwrap_or(0.0));
            r.keytrack = 100.0 * num("pitchKeyTrack").unwrap_or(1.0);
            // Volumes multiply down the chain.
            r.volume = [Some(sample), Some(*group), Some(groups_node)]
                .iter()
                .flatten()
                .filter_map(|n| n.attribute("volume"))
                .map(volume_db)
                .sum();
            r.pan = num("pan").unwrap_or(0.0) / 100.0;
            r.amp_veltrack = num("ampVelTrack").unwrap_or(1.0);
            r.amp_velcurve = Some(0);
            r.amp_eg = Envelope {
                attack: num("attack").unwrap_or(0.0),
                decay: num("decay").unwrap_or(0.0),
                sustain: num("sustain").unwrap_or(1.0),
                release: num("release").unwrap_or(0.1),
                ..Envelope::AMP
            };
            if get("ampEnvEnabled") == Some("false") {
                r.amp_eg = Envelope::AMP;
            }
            r.trigger = match get("trigger") {
                Some("release") => Trigger::Release,
                Some("first") => Trigger::First,
                Some("legato") => Trigger::Legato,
                _ => Trigger::Attack,
            };
            if let Some(decay) = get("releaseTriggerDecay") {
                r.rt_decay = rt_decay(decay);
            }
            match get("seqMode") {
                Some("round_robin") => {
                    r.seq_mode = SeqMode::RoundRobin;
                    r.seq_length = num("seqLength").map_or(auto_length, |v| v.max(1.0) as u32);
                    r.seq_position = num("seqPosition").map_or(1, |v| v.max(1.0) as u32);
                }
                Some("random") | Some("true_random") => {
                    r.seq_mode = SeqMode::Random;
                    r.seq_length = num("seqLength").map_or(auto_length, |v| v.max(1.0) as u32);
                    r.seq_position = num("seqPosition").map_or(1, |v| v.max(1.0) as u32);
                }
                _ => {}
            }
            let loop_on = get("loopEnabled").map(|v| v == "true");
            r.loop_start = num("loopStart").map(|v| v.max(0.0) as u64);
            r.loop_end = num("loopEnd").map(|v| v.max(0.0) as u64);
            r.loop_mode = match loop_on {
                Some(true) => Some(LoopMode::Continuous),
                Some(false) => Some(LoopMode::NoLoop),
                None => None,
            };
            r.loop_crossfade_frames = num("loopCrossfade").map_or(0, |v| v.max(0.0) as u64);
            if let Some(n) = num("delay") {
                match get("delayUnit").unwrap_or("seconds") {
                    "seconds" => r.delay = n,
                    other => inst.warn(format!("delayUnit `{other}` is not played")),
                }
            }
            // Controller conditions: `loCCN`, `hiCCN`, the sample's before the group's.
            let mut seen: Vec<(u8, bool)> = Vec::new();
            for attr in sample.attributes().chain(group.attributes()) {
                for (prefix, lo) in [("loCC", true), ("hiCC", false)] {
                    let Some(cc) = attr.name().strip_prefix(prefix).and_then(|n| n.parse::<u8>().ok()) else {
                        continue;
                    };
                    if cc >= 128 || seen.contains(&(cc, lo)) {
                        continue;
                    }
                    seen.push((cc, lo));
                    let v = attr.value().parse::<f32>().unwrap_or(0.0) / 127.0;
                    let i = match r.cc_ranges.iter().position(|c| c.cc == cc) {
                        Some(i) => i,
                        None => {
                            r.cc_ranges.push(CcRange { cc, lo: 0.0, hi: 1.0 });
                            r.cc_ranges.len() - 1
                        }
                    };
                    if lo { r.cc_ranges[i].lo = v } else { r.cc_ranges[i].hi = v }
                }
            }
            if let Some(previous) = get("previousNotes") {
                r.sw_previous = previous.split(',').next().and_then(parse_key).map(|k| k.clamp(0, 127) as u8);
            }
            let tags: Vec<&str> = get("tags")
                .map(|t| t.split(',').map(str::trim).filter(|t| !t.is_empty()).collect())
                .unwrap_or_default();
            // Switch layers this sample needs: its group's, its tags'.
            if let Some(l) = layer_of_group(gi) {
                r.switch_all |= 1 << l;
            }
            let mut off = false;
            for t in &tags {
                match layer_of_tag(t) {
                    Some(l) => r.switch_all |= 1 << l,
                    None if !tag_on(t) => off = true,
                    None => {}
                }
            }
            if off {
                continue;
            }
            r.groups = tags.iter().map(|t| tag_id(t)).collect();
            r.polyphony = tags
                .iter()
                .filter_map(|t| tag_polyphony.iter().find(|p| p.0 == *t).map(|p| p.1))
                .min();
            r.off_by = get("silencedByTags")
                .map(|t| t.split(',').map(str::trim).filter(|t| !t.is_empty()).map(&mut tag_id).collect())
                .unwrap_or_default();
            r.off_fast = get("silencingMode") != Some("normal");
            if let Some(decay) = num("silencingDecay").filter(|d| *d > 0.0) {
                r.off_fast = false;
                r.off_time = decay;
            } else if !r.off_fast {
                r.off_time = r.amp_eg.release;
            }
            inst.regions.push(r);
        }
    }
    for name in ["effects", "modulators", "buses"] {
        if child(root, name).is_some_and(|n| n.children().any(|c| c.is_element())) {
            inst.warn(format!("<{name}> is not played"));
        }
    }
    Ok(inst)
}

fn child<'a, 'i>(node: Node<'a, 'i>, name: &str) -> Option<Node<'a, 'i>> {
    node.children().find(|n| n.is_element() && n.tag_name().name() == name)
}

/// The group and tag bindings under a node that set `ENABLED` to a fixed value.
fn enables(node: Node, groups: &[Node]) -> Vec<Enable> {
    let mut out = Vec::new();
    for b in node.children().filter(|n| n.has_tag_name("binding")) {
        if b.attribute("enabled") == Some("false") {
            continue;
        }
        let on = b.attribute("translationValue").is_none_or(|v| v == "true" || v == "1");
        match (b.attribute("level"), b.attribute("parameter")) {
            (Some("group"), Some("ENABLED")) => {
                let index = b
                    .attribute("groupIndex")
                    .or_else(|| b.attribute("position"))
                    .and_then(|p| p.parse::<usize>().ok());
                if let Some(g) = index.filter(|&g| g < groups.len()) {
                    out.push(Enable::Group(g, on));
                }
            }
            (Some("tag"), Some("TAG_ENABLED")) => {
                if let Some(t) = b.attribute("identifier") {
                    out.push(Enable::Tag(t.to_string(), on));
                }
            }
            _ => {}
        }
    }
    out
}

/// A volume as Decent Sampler writes it: linear, or with `dB` after it.
fn volume_db(text: &str) -> f32 {
    let t = text.trim();
    if let Some(db) = t.strip_suffix("dB").or_else(|| t.strip_suffix("db")) {
        return db.trim().parse().unwrap_or(0.0);
    }
    let linear: f32 = t.parse().unwrap_or(1.0);
    if linear <= 0.0 { -144.0 } else { 20.0 * linear.log10() }
}

/// `releaseTriggerDecay` as dB per second.
fn rt_decay(text: &str) -> f32 {
    let t = text.trim();
    if let Some(db) = t.strip_suffix("dB").or_else(|| t.strip_suffix("db")) {
        return db.trim().parse::<f32>().unwrap_or(0.0).abs();
    }
    // A linear factor lost per second.
    let factor: f32 = t.parse().unwrap_or(0.0);
    if factor <= 0.0 || factor >= 1.0 { 0.0 } else { -20.0 * (1.0 - factor).log10() }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read_text(text: &str) -> Instrument {
        let doc = Document::parse(text).unwrap();
        read_document(&doc, Path::new("/lib")).unwrap()
    }

    #[test]
    fn groups_samples_and_inheritance() {
        let i = read_text(
            r#"<DecentSampler><groups attack="0.01" volume="-6dB">
                <group name="Sustain" release="0.5" volume="0.5" seqMode="round_robin">
                  <sample path="Samples/A.wav" rootNote="60" loNote="58" hiNote="62" seqPosition="1"/>
                  <sample path="Samples/B.wav" rootNote="60" loNote="58" hiNote="62" seqPosition="2" pan="50"/>
                </group></groups></DecentSampler>"#,
        );
        assert_eq!(i.regions.len(), 2);
        let r = &i.regions[1];
        assert_eq!(r.source, Source::File("/lib/Samples/B.wav".into()));
        assert_eq!((r.lokey, r.hikey, r.keycenter), (58, 62, Some(60)));
        assert_eq!(r.amp_eg.attack, 0.01);
        assert_eq!(r.amp_eg.release, 0.5);
        assert!((r.volume - (-6.0 - 6.0206)).abs() < 0.01);
        assert_eq!(r.pan, 0.5);
        assert_eq!((r.seq_length, r.seq_position), (2, 2));
    }

    #[test]
    fn keyswitch_notes_enable_groups() {
        let i = read_text(
            r#"<DecentSampler><groups>
                <group name="Sustain"><sample path="a.wav" rootNote="60"/></group>
                <group name="Staccato" enabled="false"><sample path="b.wav" rootNote="60"/></group>
                <group name="Pads"><sample path="c.wav" rootNote="60"/></group>
              </groups>
              <midi>
                <note note="24"><binding type="general" level="group" position="0" parameter="ENABLED" translation="fixed_value" translationValue="true"/>
                                <binding type="general" level="group" position="1" parameter="ENABLED" translation="fixed_value" translationValue="false"/></note>
                <note note="25" swallowNotes="true"><binding type="general" level="group" groupIndex="0" parameter="ENABLED" translation="fixed_value" translationValue="false"/>
                                <binding type="general" level="group" groupIndex="1" parameter="ENABLED" translation="fixed_value" translationValue="true"/></note>
              </midi></DecentSampler>"#,
        );
        assert_eq!(i.regions.len(), 3);
        assert_eq!(i.articulations.len(), 2);
        assert_eq!(i.articulations[0].name, "Sustain");
        assert_eq!(i.articulations[1].name, "Staccato");
        assert_eq!(i.articulations[1].m2, Some(0x110000));
        assert_eq!(i.articulations[1].keyswitch, Some(25));
        assert_eq!(i.default_switch, 0b01);
        assert_eq!(i.default_articulation, Some(0));
        assert_eq!(i.regions[0].switch_all, 0b01);
        assert_eq!(i.regions[1].switch_all, 0b10);
        assert_eq!(i.regions[2].switch_all, 0, "a group no keyswitch touches plays always");
        assert!(i.switches[1].swallow);
    }

    #[test]
    fn tags_choke_and_release_triggers() {
        let i = read_text(
            r#"<DecentSampler><tags><tag name="off" enabled="false"/></tags><groups>
                <group><sample path="open.wav" rootNote="46" tags="hat" silencedByTags="closed"/>
                       <sample path="closed.wav" rootNote="42" tags="closed,hat"/>
                       <sample path="never.wav" rootNote="40" tags="off"/>
                       <sample path="rel.wav" rootNote="60" trigger="release" releaseTriggerDecay="3dB"/></group>
              </groups></DecentSampler>"#,
        );
        assert_eq!(i.regions.len(), 3, "a sample with a disabled tag never plays");
        assert_eq!(i.regions[0].off_by, i.regions[1].groups[..1].to_vec());
        assert_eq!(i.regions[2].trigger, Trigger::Release);
        assert_eq!(i.regions[2].rt_decay, 3.0);
    }
}
