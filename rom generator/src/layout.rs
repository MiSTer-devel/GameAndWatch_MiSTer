use std::{collections::HashMap, fs, path::Path};

use serde::Deserialize;

use serde_xml_rs;

#[derive(Debug, Deserialize)]
pub struct MameLayout {
    pub element: Vec<NameElement>,
    pub view: Vec<View>,
}

#[derive(Debug, Deserialize)]
pub struct NameElement {
    pub name: String,
    pub defstate: Option<i32>,
    #[serde(rename = "$value")]
    pub items: Vec<NameElementChildren>,
}

#[derive(PartialEq, Debug, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum NameElementChildren {
    Image(Image),
    Rect(Rect),
}

#[derive(PartialEq, Debug, Deserialize)]
pub struct Image {
    pub file: String,
    pub state: Option<i32>,
}

#[derive(PartialEq, Debug, Deserialize)]
pub struct Rect {}

#[derive(Clone, Debug, Deserialize)]
pub struct View {
    pub name: String,
    // element: Vec<RefElement>,
    // pub screen: Vec<Screen>,
    #[serde(rename = "$value")]
    pub items: Vec<ViewElement>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ViewElement {
    Bounds(ViewBounds),
    #[serde(alias = "bezel")]
    Element(Element),
    Overlay(Element),
    Screen(Screen),
}

// A view bound establishes the MAME viewport but is not rendered directly.
// Keep its attributes permissive; artwork may use negative or fractional
// coordinates and serde-xml-rs does not handle it reliably as CompleteBounds
// inside the mixed view-item enum.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct ViewBounds {
    pub x: Option<f32>,
    pub y: Option<f32>,
    pub width: Option<f32>,
    pub height: Option<f32>,
    pub left: Option<f32>,
    pub right: Option<f32>,
    pub top: Option<f32>,
    pub bottom: Option<f32>,
}

impl ViewBounds {
    pub fn to_xy(&self) -> Bounds {
        if let (Some(x), Some(y), Some(width), Some(height)) =
            (self.x, self.y, self.width, self.height)
        {
            return Bounds {
                x: x.round() as i32,
                y: y.round() as i32,
                width: width.round() as i32,
                height: height.round() as i32,
            };
        }
        if let (Some(left), Some(right), Some(top), Some(bottom)) =
            (self.left, self.right, self.top, self.bottom)
        {
            return Bounds {
                x: left.round() as i32,
                y: top.round() as i32,
                width: (right - left).round() as i32,
                height: (bottom - top).round() as i32,
            };
        }
        panic!("View bounds appear to have an invalid format {self:?}");
    }
}

#[derive(Clone, Debug, Deserialize)]
pub struct XYBounds {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

#[derive(Clone, Debug, Deserialize)]
pub struct CompleteBounds {
    // Standard XY
    pub x: Option<Coordinate>,
    pub y: Option<Coordinate>,
    pub width: Option<Coordinate>,
    pub height: Option<Coordinate>,

    // Center
    pub xc: Option<Coordinate>,
    pub yc: Option<Coordinate>,

    // LeftRight
    pub left: Option<Coordinate>,
    pub right: Option<Coordinate>,
    pub top: Option<Coordinate>,
    pub bottom: Option<Coordinate>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(untagged)]
pub enum Coordinate {
    Integer(i32),
    Symbol(String),
}

#[derive(Clone, Copy, Debug)]
pub struct NativeScreenSize {
    pub width: f32,
    pub height: f32,
}

impl Coordinate {
    fn value(&self, screens: &[NativeScreenSize]) -> Result<i32, String> {
        match self {
            Coordinate::Integer(value) => Ok(*value),
            Coordinate::Symbol(value) => {
                // serde-xml-rs may deserialize numeric XML attributes through
                // the string arm of this untagged enum. Preserve fractional
                // layout coordinates by accepting them here as well.
                if let Ok(number) = value.parse::<f32>() {
                    return Ok(number.round() as i32);
                }

                let symbol = value
                    .strip_prefix("~scr")
                    .and_then(|value| value.strip_suffix('~'))
                    .ok_or_else(|| format!("Unsupported MAME layout coordinate {value:?}"))?;
                let axis_start = symbol
                    .find(|character: char| !character.is_ascii_digit())
                    .ok_or_else(|| format!("Unsupported MAME layout coordinate {value:?}"))?;
                let (screen_index, axis) = symbol.split_at(axis_start);
                let screen_index: usize = screen_index
                    .parse()
                    .map_err(|_| format!("Unsupported MAME layout coordinate {value:?}"))?;
                let screen = screens.get(screen_index).ok_or_else(|| {
                    format!(
                        "MAME layout coordinate {value:?} references missing screen {screen_index}"
                    )
                })?;

                let coordinate = match axis {
                    "width" => screen.width,
                    "height" => screen.height,
                    _ => {
                        return Err(format!(
                            "Unsupported MAME layout coordinate {value:?}"
                        ))
                    }
                };

                Ok(coordinate.round() as i32)
            }
        }
    }
}

#[derive(Clone, Debug)]
pub struct Bounds {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

// This is written in such garbage form because serde_xml_rs doesn't support untagged enums, so I can't get it to
// properly build enums with the different Bounds variants
impl CompleteBounds {
    pub fn to_xy(&self, screens: &[NativeScreenSize]) -> Result<Bounds, String> {
        if let (Some(x), Some(y), Some(width), Some(height)) =
            (&self.x, &self.y, &self.width, &self.height)
        {
            // XY
            Ok(Bounds {
                x: x.value(screens)?,
                y: y.value(screens)?,
                width: width.value(screens)?,
                height: height.value(screens)?,
            })
        } else if let (Some(xc), Some(yc), Some(width), Some(height)) =
            (&self.xc, &self.yc, &self.width, &self.height)
        {
            // Center
            let width = width.value(screens)?;
            let height = height.value(screens)?;
            Ok(Bounds {
                x: xc.value(screens)? - width,
                y: yc.value(screens)? - height,
                width,
                height,
            })
        } else if let (Some(left), Some(right), Some(top), Some(bottom)) =
            (&self.left, &self.right, &self.top, &self.bottom)
        {
            let left = left.value(screens)?;
            let right = right.value(screens)?;
            let top = top.value(screens)?;
            let bottom = bottom.value(screens)?;
            Ok(Bounds {
                x: left,
                y: top,
                width: right - left,
                height: bottom - top,
            })
        } else {
            Err(format!("Bounds appear to have an invalid format {self:?}"))
        }
    }
}

#[derive(Clone, Debug, Deserialize)]
pub struct Element {
    #[serde(rename = "ref")]
    #[serde(alias = "element")]
    pub ref_name: String,
    pub bounds: CompleteBounds,
    pub blend: Option<BlendType>,
}

#[derive(Clone, PartialEq, Debug, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum BlendType {
    Add,
    Alpha,
    Multiply,
}

#[derive(Clone, Debug, Deserialize)]
pub struct Screen {
    pub index: i32,
    pub bounds: CompleteBounds,
    pub blend: Option<BlendType>,
}

pub fn parse_layout(
    temp_dir: &Path,
    specified_layout: Option<&String>,
) -> Result<(MameLayout, View), String> {
    let layout_path = temp_dir.join("default.lay");
    let layout_file = match fs::read(&layout_path) {
        Ok(layout_file) => layout_file,
        Err(_) => {
            return Err(format!(
                "Could not find default.lay file at path {layout_path:?}"
            ))
        }
    };

    // A few preserved MAME artwork packs contain small, well-known XML typos
    // in views we do not select (a missing '<' before bounds or a stray
    // "en>" after </bezel>). Repair only those exact malformed tokens before
    // deserializing so valid layout semantics remain untouched.
    let layout_text = String::from_utf8(layout_file)
        .map_err(|err| format!("Layout {layout_path:?} is not UTF-8: {err}"))?;
    let layout_text = layout_text
        .replace("\nbounds x=", "\n<bounds x=")
        .replace("</bezel>en>", "</bezel>");

    // let output: MameLayout = match serde_xml_rs::from_reader(layout_file.as_slice()) {
    //     Ok(output) => output,
    //     Err(err) => {
    //         return Err(format!("Could not parse layout: \"{err}\""))},
    // };
    let output: MameLayout = serde_xml_rs::from_reader(layout_text.as_bytes())
        .map_err(|err| format!("Could not parse layout {layout_path:?}: {err}"))?;

    let mut map = HashMap::<String, View>::new();

    for view in output.view.iter() {
        map.insert(view.name.to_lowercase(), view.clone());
    }

    if let Some(specified_layout) = specified_layout {
        if let Some(view) = map.remove(&specified_layout.trim().to_lowercase()) {
            return Ok((output, view));
        } else {
            return Err(format!("Could not find view named \"{specified_layout}\""));
        }
    }

    guard!(let Some(view) = select_view(&mut map) else {
        return Err("Could not find suitable view".to_string());
    });

    Ok((output, view))
}

fn select_view(views: &mut HashMap<String, View>) -> Option<View> {
    // Constructed this way to give ordered priority to each view name we want
    let desired_names = vec![
        "backgrounds only (no frame)",
        "background only (no frame)",
        "backgrounds only (no shadow)",
        "background only (no shadow)",
        "backgrounds only",
        "background only",
        "background",
        "handheld layout",
        "external layout",
        "screen focus",
        "unit only",
    ];

    for name in desired_names {
        if let Some(view) = views.remove(name) {
            return Some(view);
        }

        // Artwork collections commonly prefix the standard view name with a
        // revision label (for example, "Version 1 - Background Only"). Pick
        // the lexically first match so the result is stable across runs.
        let suffix = format!(" - {name}");
        let matching_name = views
            .keys()
            .filter(|candidate| candidate.ends_with(&suffix))
            .min()
            .cloned();

        if let Some(matching_name) = matching_name {
            return views.remove(&matching_name);
        }
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn empty_view(name: &str) -> View {
        View {
            name: name.to_string(),
            items: vec![],
        }
    }

    #[test]
    fn selects_prefixed_standard_view_deterministically() {
        let mut views = HashMap::new();
        views.insert(
            "version 2 - background only (no shadow)".to_string(),
            empty_view("Version 2 - Background Only (No Shadow)"),
        );
        views.insert(
            "version 1 - background only (no shadow)".to_string(),
            empty_view("Version 1 - Background Only (No Shadow)"),
        );

        let selected = select_view(&mut views).expect("expected a matching view");
        assert_eq!(selected.name, "Version 1 - Background Only (No Shadow)");
    }

    #[test]
    fn resolves_symbolic_bounds_to_the_native_screen_aspect() {
        let bounds = CompleteBounds {
            x: None,
            y: None,
            width: None,
            height: None,
            xc: None,
            yc: None,
            left: Some(Coordinate::Integer(0)),
            right: Some(Coordinate::Symbol("~scr0width~".to_string())),
            top: Some(Coordinate::Integer(0)),
            bottom: Some(Coordinate::Symbol("~scr0height~".to_string())),
        };

        let resolved = bounds
            .to_xy(&[NativeScreenSize {
                width: 1715.0,
                height: 1080.0,
            }])
            .expect("symbolic screen bounds should resolve");

        assert_eq!(resolved.x, 0);
        assert_eq!(resolved.y, 0);
        assert_eq!(resolved.width, 1715);
        assert_eq!(resolved.height, 1080);
    }

    #[test]
    fn resolves_the_requested_screen_index_and_rejects_unknown_symbols() {
        let screens = [
            NativeScreenSize {
                width: 100.0,
                height: 200.0,
            },
            NativeScreenSize {
                width: 300.0,
                height: 400.0,
            },
        ];

        assert_eq!(
            Coordinate::Symbol("~scr1width~".to_string()).value(&screens),
            Ok(300)
        );
        assert!(Coordinate::Symbol("~scr0depth~".to_string())
            .value(&screens)
            .is_err());
    }
}
