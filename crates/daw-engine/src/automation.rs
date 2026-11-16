//! Automation as the audio thread sees it: per track, the lanes that are on,
//! each a list of points in the target's own units.

use crate::engine::Slot;

/// The value of a lane at `beat`: linear between points, the first value
/// before the first point and the last after the last. `points` must be sorted
/// by beat; where two share a beat, the later one wins from that beat on.
pub fn value_at(points: &[(f64, f64)], beat: f64) -> Option<f64> {
    let next = points.partition_point(|p| p.0 <= beat);
    match (next.checked_sub(1).map(|i| points[i]), points.get(next)) {
        (None, None) => None,
        (Some(a), None) => Some(a.1),
        (None, Some(b)) => Some(b.1),
        (Some(a), Some(b)) => Some(a.1 + (b.1 - a.1) * (beat - a.0) / (b.0 - a.0)),
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum AutoTarget {
    /// The fader, with points in dB.
    Volume,
    /// -1 (left) to 1 (right).
    Pan,
    /// A parameter, by position in the device's parameter list.
    Param { device: Slot, index: u32 },
}

pub struct AutoLane {
    pub target: AutoTarget,
    pub points: Box<[(f64, f64)]>,
    /// The parameter value last sent, so that a device only hears about changes.
    pub(crate) last: f64,
}

impl AutoLane {
    pub fn new(target: AutoTarget, points: impl Into<Box<[(f64, f64)]>>) -> Self {
        Self {
            target,
            points: points.into(),
            last: f64::NAN,
        }
    }
}

/// Every active lane of one track. Built on the main thread and handed to the
/// engine whole, like a [`ClipSet`](crate::ClipSet).
#[derive(Default)]
pub struct Automation {
    pub lanes: Vec<AutoLane>,
}

#[cfg(test)]
mod tests {
    use super::value_at;

    #[test]
    fn interpolates_and_holds() {
        let points = [(2.0, -60.0), (6.0, 0.0), (6.0, -12.0)];
        assert_eq!(value_at(&[], 1.0), None);
        assert_eq!(value_at(&points, 0.0), Some(-60.0));
        assert_eq!(value_at(&points, 4.0), Some(-30.0));
        assert_eq!(value_at(&points, 6.0), Some(-12.0));
        assert_eq!(value_at(&points, 100.0), Some(-12.0));
    }
}
