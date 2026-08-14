use std::{collections::HashSet, path::Path};

use image::{imageops::FilterType, DynamicImage, ImageBuffer, Rgba};
use resvg::tiny_skia::{FilterQuality, Pixmap, PixmapPaint, PremultipliedColorU8};
use tiny_skia_path::Transform;

use crate::{
    layout::{
        BlendType, Bounds, Element, Image as LayoutImage, MameLayout, NameElement,
        NameElementChildren, NativeScreenSize, Screen, View, ViewElement,
    },
    manifest::{self, PlatformSpecification, PresetDefinition},
    svg_manage::build_svg,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RenderTarget {
    pub output_width: usize,
    pub output_height: usize,
    pub logical_width: usize,
    pub logical_height: usize,
    pub debug_suffix: &'static str,
}

impl RenderTarget {
    pub const fn native() -> Self {
        Self {
            output_width: 720,
            output_height: 720,
            logical_width: 720,
            logical_height: 720,
            debug_suffix: "",
        }
    }

    pub const fn crt() -> Self {
        Self {
            output_width: 360,
            output_height: 240,
            // Lay the artwork out on a square-pixel 4:3 canvas first, then
            // expand the complete composition into the 360-sample transport.
            logical_width: 320,
            logical_height: 240,
            debug_suffix: "_crt",
        }
    }

    fn logical_pixel_count(self) -> usize {
        self.logical_width * self.logical_height
    }
}

pub struct RenderedData {
    pub background_bytes: Pixmap,
    pub mask_bytes: Pixmap,
    pub pixels_to_mask_id: Vec<Option<u16>>,
}

pub fn render(
    platform_name: &str,
    layout: &View,
    layout_manifest: &MameLayout,
    platform: &PlatformSpecification,
    asset_dir: &Path,
    target: RenderTarget,
    debug: bool,
) -> Result<RenderedData, String> {
    if target.output_width == 0
        || target.output_height == 0
        || target.logical_width == 0
        || target.logical_height == 0
    {
        return Err("Render target dimensions must be nonzero".to_string());
    }

    let native_screen_sizes = native_screen_sizes(&platform.device.screen);
    let mut view_bounds: Option<Bounds> = None;
    let mut elements: Vec<&Element> = vec![];
    let mut screens: Vec<&Screen> = vec![];

    let mut filtered_items: Vec<&ViewElement> = vec![];

    // Keep track of which refs have already been added to the image, as most layouts contain multiple duplicates
    let mut already_applied_refs: HashSet<&String> = HashSet::<&String>::new();

    // Prefilter all items
    for item in &layout.items {
        match item {
            ViewElement::Bounds(bounds) => {
                // Filter out
                if view_bounds.is_some() {
                    return Err(format!(
                        "View {} in {platform_name} has multiple bounds. Skipping",
                        layout.name
                    ));
                }
                view_bounds = Some(bounds.to_xy());
            }
            ViewElement::Element(element) | ViewElement::Overlay(element) => {
                if already_applied_refs.contains(&element.ref_name) {
                    continue;
                }

                already_applied_refs.insert(&element.ref_name);

                match element.ref_name.to_lowercase().as_str() {
                    "dust" | "bubbles" | "unit" | "backdrop" => {
                        // Ignore these features
                        println!("Ignoring element by name {}", element.ref_name);
                        continue;
                    }
                    value => {
                        // if value.starts_with("fix") || value.starts_with("gradient") {
                        if value.starts_with("gradient") {
                            println!("Ignoring element by name {}", element.ref_name);
                            continue;
                        }
                    }
                }

                filtered_items.push(item);
                elements.push(element);
            }
            ViewElement::Screen(screen) => {
                filtered_items.push(item);
                screens.push(screen);
            }
        }
    }

    // Calculate actual bounds
    let mut min_x: Option<i32> = None;
    let mut min_y: Option<i32> = None;
    let mut max_width = 0;
    let mut max_height = 0;
    let mut max_common_x: Option<i32> = None;
    let mut max_common_y: Option<i32> = None;

    // Calculate max bounds
    // Only Element nodes are used, as Screen's should not drive the overall picture size (they sometimes overrun it)
    for element in &elements {
        let bounds = element.bounds.to_xy(&native_screen_sizes)?;
        if let Some(inner_min_x) = min_x {
            if inner_min_x > bounds.x {
                min_x = Some(bounds.x);
            }
        }

        if let Some(inner_min_y) = min_y {
            if inner_min_y > bounds.y {
                min_y = Some(bounds.y);
            }
        }

        if bounds.width + bounds.x > max_width {
            max_width = bounds.width + bounds.x;
        }

        if bounds.height + bounds.y > max_height {
            max_height = bounds.height + bounds.y;
        }

        if let Some(common_x) = max_common_x {
            if common_x > bounds.x {
                // Shorten max common
                max_common_x = Some(bounds.x);
            }
        } else {
            // Set first value
            max_common_x = Some(bounds.x);
        }

        if let Some(common_y) = max_common_y {
            if common_y > bounds.y {
                // Shorten max common
                max_common_y = Some(bounds.y);
            }
        } else {
            // Set first value
            max_common_y = Some(bounds.y);
        }
    }

    let max_common_x = max_common_x.map_or(0, |x| x.max(0));
    let max_common_y = max_common_y.map_or(0, |y| y.max(0));

    let view_bounds = Bounds {
        x: (min_x.map_or(0, |x| x) - max_common_x).max(0),
        y: (min_y.map_or(0, |y| y) - max_common_y).max(0),
        width: max_width - max_common_x,
        height: max_height - max_common_y,
    };

    if view_bounds.width <= 0 || view_bounds.height <= 0 {
        return Err(format!(
            "View {} in {platform_name} has invalid bounds {view_bounds:?}",
            layout.name
        ));
    }

    let x_ratio = target.logical_width as f32 / view_bounds.width as f32;
    let y_ratio = target.logical_height as f32 / view_bounds.height as f32;

    let (ratio, x_scale) = if x_ratio < y_ratio {
        // Scaling based on X
        (x_ratio, true)
    } else {
        (y_ratio, false)
    };

    let (x_offset, y_offset) = if !x_scale {
        let scaled_width = view_bounds.width as f32 * ratio;
        (
            (target.logical_width as i32 - scaled_width.round() as i32) / 2,
            0,
        )
    } else {
        let scaled_height = view_bounds.height as f32 * ratio;
        (
            0,
            (target.logical_height as i32 - scaled_height.round() as i32) / 2,
        )
    };

    // Keep track of the set of pixels that make up each screen
    let mut pixels_to_mask_id: Vec<Option<u16>> = vec![None; target.logical_pixel_count()];

    let mut background_pixmap =
        Pixmap::new(target.logical_width as u32, target.logical_height as u32).unwrap();
    let mut mask_pixmap =
        Pixmap::new(target.logical_width as u32, target.logical_height as u32).unwrap();

    // We currently ignore offsetting by X/Y at the parent view, so the child positions are subtracted
    // from the parent's offset
    for item in &filtered_items {
        match item {
            ViewElement::Element(element) | ViewElement::Overlay(element) => {
                let layout_element = layout_manifest
                    .element
                    .iter()
                    .find(|candidate| candidate.name == element.ref_name);

                let Some(layout_image) = layout_element.and_then(select_element_image) else {
                    // There is no defined element with this name OR the defined element does not have image data
                    // Skip
                    continue;
                };

                let file_path = asset_dir.join(&layout_image.file);

                let image = load_element_image(&file_path).map_err(|error| {
                    format!(
                        "Could not load element asset \"{}\" from {file_path:?}: {error}",
                        element.ref_name
                    )
                })?;

                let element_bounds = element.bounds.to_xy(&native_screen_sizes)?;

                let x = if element_bounds.x >= 0 {
                    // Only normalize to 0 if we started out positive
                    (element_bounds.x - max_common_x).max(0)
                } else {
                    element_bounds.x - max_common_x
                };

                let y = if element_bounds.y >= 0 {
                    // Only normalize to 0 if we started out positive
                    (element_bounds.y - max_common_y).max(0)
                } else {
                    element_bounds.y - max_common_y
                };

                let element_bounds = Bounds {
                    x,
                    y,
                    width: element_bounds.width,
                    height: element_bounds.height,
                };

                let dimensions = ImageDimensions::new(
                    &view_bounds,
                    &element_bounds,
                    ratio,
                    x_offset,
                    y_offset,
                    target,
                );

                let image: DynamicImage = DynamicImage::ImageRgba8(image).resize_exact(
                    dimensions.width,
                    dimensions.height,
                    FilterType::CatmullRom,
                );

                // Dimensions might change by a pixel as part of resizing
                let image_width = image.width();
                let image_height = image.height();

                guard!(let Some(image_map) = Pixmap::from_vec(
                    image.into_bytes(),
                    tiny_skia_path::IntSize::from_wh(image_width, image_height).unwrap(),
                ) else {
                    return Err(format!("Could not convert PNG into Pixmap"));
                });

                let mut aligned_image_pixmap = Pixmap::new(
                    target.logical_width as u32,
                    target.logical_height as u32,
                )
                .unwrap();

                // This is inefficient, but I don't want to calculate the bounds changes
                aligned_image_pixmap.draw_pixmap(
                    dimensions.x,
                    dimensions.y,
                    image_map.as_ref(),
                    &PixmapPaint::default(),
                    Transform::identity(),
                    None,
                );

                let blend = if let ViewElement::Overlay(_) = item {
                    Some(&BlendType::Multiply)
                } else {
                    element.blend.as_ref()
                };

                let blend_func = match blend {
                    Some(BlendType::Add) | Some(BlendType::Alpha) | None => alpha_blend_colors,
                    Some(BlendType::Multiply) => multiply_blend_colors,
                };

                let white_pixel = PremultipliedColorU8::from_rgba(255, 255, 255, 255).unwrap();

                // We have to go pixel by pixel and check if they're in the mask
                let pixels = aligned_image_pixmap.pixels();
                let mask_pixels = mask_pixmap.pixels_mut();
                let background_pixels = background_pixmap.pixels_mut();
                for i in 0..target.logical_pixel_count() {
                    let pixel = pixels[i];
                    if pixel.alpha() == 0 {
                        continue;
                    }

                    let background_pixel = if blend == Some(&BlendType::Multiply)
                        && background_pixels[i].alpha() == 0
                    {
                        // Value was never set, mulitply would fail
                        white_pixel
                    } else {
                        background_pixels[i]
                    };

                    if pixels_to_mask_id[i].is_some() {
                        // A mask pixel is at this location
                        mask_pixels[i] = blend_func(mask_pixels[i], pixel);

                        // Also write through to the background
                        background_pixels[i] = blend_func(background_pixel, pixel);
                    } else {
                        // No mask pixel, write to background
                        background_pixels[i] = blend_func(background_pixel, pixel);
                    }
                }
            }
            ViewElement::Screen(screen) => {
                let file_path = asset_dir.join("foo").with_file_name(screen_filename(
                    screen.index as usize,
                    platform_name,
                    &platform.device,
                ));

                let alternate_file_path = platform
                    .parent
                    .as_ref()
                    .or(platform.rom.rom_owner.as_ref())
                    .map(|parent| {
                        asset_dir.join("foo").with_file_name(screen_filename(
                            screen.index as usize,
                            parent,
                            &platform.device,
                        ))
                    });

                let bounds = screen.bounds.to_xy(&native_screen_sizes)?;

                let x = if bounds.x >= 0 {
                    // Only normalize to 0 if we started out positive
                    (bounds.x - max_common_x).max(0)
                } else {
                    bounds.x - max_common_x
                };

                let y = if bounds.y >= 0 {
                    // Only normalize to 0 if we started out positive
                    (bounds.y - max_common_y).max(0)
                } else {
                    bounds.y - max_common_y
                };

                let bounds = Bounds {
                    x,
                    y,
                    width: bounds.width,
                    height: bounds.height,
                };

                let dimensions = ImageDimensions::new(
                    &view_bounds,
                    &bounds,
                    ratio,
                    x_offset,
                    y_offset,
                    target,
                );

                // TODO: We don't really have a way to scale SVGs that won't result in a quality loss
                // so that isn't handled here
                let rendered_svg = build_svg(&file_path, &alternate_file_path, &dimensions)?;

                // Draw actual LCD pixels
                mask_pixmap.draw_pixmap(
                    // This image is already aligned
                    0,
                    0,
                    rendered_svg.pixmap.as_ref(),
                    &PixmapPaint::default(),
                    Transform::identity(),
                    None,
                );

                // Combine this screen into the global pixel ID map
                // If both have IDs, latest wins
                for i in 0..target.logical_pixel_count() {
                    if let Some(new_svg_id) = rendered_svg.pixel_pos_to_id[i] {
                        // Use this, replacing any existing pixel
                        pixels_to_mask_id[i] = Some(new_svg_id);
                    }
                }
            }
            ViewElement::Bounds(_) => {}
        }
    }

    let mut output_mask = background_pixmap.clone();

    // Draw mask over top of background, so transparency can blend to the correct colors
    output_mask.draw_pixmap(
        0,
        0,
        mask_pixmap.as_ref(),
        &PixmapPaint::default(),
        Transform::identity(),
        None,
    );

    ensure_lcd_contrast(&mut output_mask, &background_pixmap, &pixels_to_mask_id);

    // Author CRT artwork on an effective square-pixel 320x240 canvas, then
    // expand the complete composition into the 360-sample transport. resvg
    // preserves SVG aspect ratio inside its render target, so stretching only
    // element rectangles would leave LCD content narrow while raster artwork
    // filled the output width.
    let background_pixmap = expand_pixmap(&background_pixmap, target);
    let mask_pixmap = expand_pixmap(&mask_pixmap, target);
    let output_mask = expand_pixmap(&output_mask, target);
    let pixels_to_mask_id = expand_mask_ids(&pixels_to_mask_id, target);

    if debug {
        let debug_path = asset_dir.join(format!(
            "{platform_name}{}.png",
            target.debug_suffix
        ));
        let debug_background_path = asset_dir.join(format!(
            "{platform_name}{}_background.png",
            target.debug_suffix
        ));
        let debug_mask_path = asset_dir.join(format!(
            "{platform_name}{}_mask.png",
            target.debug_suffix
        ));

        let mut debug_pixmap =
            Pixmap::new(target.output_width as u32, target.output_height as u32).unwrap();

        debug_pixmap.draw_pixmap(
            0,
            0,
            background_pixmap.as_ref(),
            &PixmapPaint::default(),
            Transform::identity(),
            None,
        );

        debug_pixmap.draw_pixmap(
            0,
            0,
            mask_pixmap.as_ref(),
            &PixmapPaint::default(),
            Transform::identity(),
            None,
        );

        debug_pixmap.save_png(&debug_path).unwrap();
        background_pixmap.save_png(&debug_background_path).unwrap();
        output_mask.save_png(&debug_mask_path).unwrap();
    }

    Ok(RenderedData {
        background_bytes: background_pixmap,
        mask_bytes: output_mask,
        pixels_to_mask_id: pixels_to_mask_id,
    })
}

fn native_screen_sizes(screen: &manifest::Screen) -> Vec<NativeScreenSize> {
    let size = |width, height| NativeScreenSize { width, height };

    match screen {
        manifest::Screen::Single { width, height } => vec![size(*width, *height)],
        manifest::Screen::DualVertical { top, bottom } => vec![
            size(top.width, top.height),
            size(bottom.width, bottom.height),
        ],
        manifest::Screen::DualHorizontal { left, right } => vec![
            size(left.width, left.height),
            size(right.width, right.height),
        ],
        manifest::Screen::TripleHorizontal {
            left,
            middle,
            right,
        } => vec![
            size(left.width, left.height),
            size(middle.width, middle.height),
            size(right.width, right.height),
        ],
    }
}

fn select_element_image(element: &NameElement) -> Option<&LayoutImage> {
    let images: Vec<&LayoutImage> = element
        .items
        .iter()
        .filter_map(|item| match item {
            NameElementChildren::Image(image) => Some(image),
            NameElementChildren::Rect(_) => None,
        })
        .collect();

    if let Some(default_state) = element.defstate {
        if let Some(image) = images
            .iter()
            .find(|image| image.state == Some(default_state))
        {
            return Some(*image);
        }
    }

    images
        .iter()
        .find(|image| image.state.is_none())
        .copied()
        .or_else(|| images.first().copied())
}

fn load_element_image(file_path: &Path) -> Result<ImageBuffer<Rgba<u8>, Vec<u8>>, String> {
    let is_png = file_path
        .extension()
        .and_then(|extension| extension.to_str())
        .map(|extension| extension.eq_ignore_ascii_case("png"))
        .unwrap_or(false);

    if is_png {
        // Preserve the existing tiny-skia PNG path, which handles alpha in the
        // same premultiplied representation used by the compositor.
        if let Ok(image) = Pixmap::load_png(file_path) {
            return ImageBuffer::<Rgba<u8>, Vec<u8>>::from_vec(
                image.width(),
                image.height(),
                image.take(),
            )
            .ok_or_else(|| "could not convert PNG pixel data".to_string());
        }
    }

    image::open(file_path)
        .map(|image| image.to_rgba8())
        .map_err(|error| error.to_string())
}

fn ensure_lcd_contrast(
    output_mask: &mut Pixmap,
    background_pixmap: &Pixmap,
    pixels_to_mask_id: &[Option<u16>],
) {
    let background_pixels = background_pixmap.pixels();
    let mask_pixels = output_mask.pixels();
    debug_assert_eq!(pixels_to_mask_id.len(), background_pixels.len());
    debug_assert_eq!(pixels_to_mask_id.len(), mask_pixels.len());

    let mut segment_pixels = 0usize;
    let mut total_delta = 0usize;

    for i in 0..pixels_to_mask_id.len() {
        if pixels_to_mask_id[i].is_none() {
            continue;
        }

        segment_pixels += 1;

        let background = background_pixels[i];
        let mask = mask_pixels[i];

        total_delta += usize::from(background.red().abs_diff(mask.red()));
        total_delta += usize::from(background.green().abs_diff(mask.green()));
        total_delta += usize::from(background.blue().abs_diff(mask.blue()));
    }

    // Some MAME artwork layers are technically different from the background
    // but only by one or two RGB counts, which is invisible on the core.
    // Treat those as no-contrast LCD foregrounds and synthesize a usable
    // active-segment layer from the real mask geometry.
    let low_contrast_limit = segment_pixels * 3;

    if segment_pixels == 0 || total_delta > low_contrast_limit {
        return;
    }

    let mask_pixels = output_mask.pixels_mut();

    for i in 0..pixels_to_mask_id.len() {
        if pixels_to_mask_id[i].is_none() {
            continue;
        }

        let background = background_pixels[i];
        let lcd_red = (u16::from(background.red()) * 45 / 100) as u8;
        let lcd_green = (u16::from(background.green()) * 45 / 100) as u8;
        let lcd_blue = (u16::from(background.blue()) * 45 / 100) as u8;

        mask_pixels[i] = PremultipliedColorU8::from_rgba(lcd_red, lcd_green, lcd_blue, 255)
            .expect("Could not build contrast LCD color");
    }
}

fn alpha_blend_colors(
    background: PremultipliedColorU8,
    foreground: PremultipliedColorU8,
) -> PremultipliedColorU8 {
    let combine_values = |foreground: u8, background: u8, foreground_alpha: f32| -> u8 {
        let foreground = foreground as f32;
        let background = background as f32;

        let output = (foreground / 255.0) + (background / 255.0) * (1.0 - foreground_alpha);

        (output * 255.0).round() as u8
    };

    let foreground_alpha = foreground.alpha() as f32 / 255.0;

    let red = combine_values(foreground.red(), background.red(), foreground_alpha);
    let green = combine_values(foreground.green(), background.green(), foreground_alpha);
    let blue = combine_values(foreground.blue(), background.blue(), foreground_alpha);
    let alpha = combine_values(foreground.alpha(), background.alpha(), foreground_alpha);

    PremultipliedColorU8::from_rgba(red, green, blue, red.max(green).max(blue).max(alpha))
        .expect("Could not convert alpha blend color")
}

fn multiply_blend_colors(
    background: PremultipliedColorU8,
    foreground: PremultipliedColorU8,
) -> PremultipliedColorU8 {
    let combine_values = |foreground: u8, background: u8| -> u8 {
        let foreground = foreground as f32;
        let background = background as f32;

        let output = (foreground / 255.0) * (background / 255.0);

        let output = output.min(1.0);

        (output * 255.0).round() as u8
    };

    let red = combine_values(foreground.red(), background.red());
    let green = combine_values(foreground.green(), background.green());
    let blue = combine_values(foreground.blue(), background.blue());
    let alpha = combine_values(foreground.alpha(), background.alpha());

    PremultipliedColorU8::from_rgba(red, green, blue, red.max(green).max(blue).max(alpha))
        .expect("Could not convert multiply blend color")
}

fn screen_filename(index: usize, platform_name: &str, platform: &PresetDefinition) -> String {
    let suffix = match platform.screen {
        manifest::Screen::Single { .. } => "",
        manifest::Screen::DualVertical { .. } => {
            if index == 0 {
                "_top"
            } else {
                "_bottom"
            }
        }
        manifest::Screen::DualHorizontal { .. } => {
            if index == 0 {
                "_left"
            } else {
                "_right"
            }
        }
        manifest::Screen::TripleHorizontal { .. } => match index {
            0 => "_left",
            1 => "_middle",
            _ => "_right",
        },
    };

    format!("{platform_name}{suffix}.svg")
}

#[derive(Clone, Debug)]
pub struct ImageDimensions {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    pub canvas_width: u32,
    pub canvas_height: u32,
}

impl ImageDimensions {
    fn new(
        view_bounds: &Bounds,
        bounds: &Bounds,
        ratio: f32,
        x_offset: i32,
        y_offset: i32,
        target: RenderTarget,
    ) -> Self {
        let x = ((bounds.x as i32 - view_bounds.x as i32) as f32 * ratio).round() as i32;
        let y = ((bounds.y as i32 - view_bounds.y as i32) as f32 * ratio).round() as i32;
        let width = (bounds.width as f32 * ratio) as u32;
        let height = (bounds.height as f32 * ratio) as u32;

        // if x < 0 {
        //     println!("Unexpected X: {x} is less than 0");
        // }

        // if y < 0 {
        //     println!("Unexpected Y: {y} is less than 0");
        // }

        ImageDimensions {
            x: x + x_offset,
            y: y + y_offset,
            width,
            height,
            canvas_width: target.logical_width as u32,
            canvas_height: target.logical_height as u32,
        }
    }
}

fn expand_pixmap(source: &Pixmap, target: RenderTarget) -> Pixmap {
    if target.logical_width == target.output_width
        && target.logical_height == target.output_height
    {
        return source.clone();
    }

    let mut output = Pixmap::new(target.output_width as u32, target.output_height as u32)
        .expect("Could not allocate expanded render target");
    let mut paint = PixmapPaint::default();
    paint.quality = FilterQuality::Bicubic;
    output.draw_pixmap(
        0,
        0,
        source.as_ref(),
        &paint,
        Transform::from_scale(
            target.output_width as f32 / target.logical_width as f32,
            target.output_height as f32 / target.logical_height as f32,
        ),
        None,
    );
    output
}

fn expand_mask_ids(source: &[Option<u16>], target: RenderTarget) -> Vec<Option<u16>> {
    debug_assert_eq!(source.len(), target.logical_pixel_count());
    if target.logical_width == target.output_width
        && target.logical_height == target.output_height
    {
        return source.to_vec();
    }

    let mut output = vec![None; target.output_width * target.output_height];
    for output_y in 0..target.output_height {
        let source_y = (((output_y as f64 + 0.5) * target.logical_height as f64
            / target.output_height as f64)
            .floor() as usize)
            .min(target.logical_height - 1);
        for output_x in 0..target.output_width {
            let source_x = (((output_x as f64 + 0.5) * target.logical_width as f64
                / target.output_width as f64)
                .floor() as usize)
                .min(target.logical_width - 1);
            output[output_y * target.output_width + output_x] =
                source[source_y * target.logical_width + source_x];
        }
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;

    fn layout_image(file: &str, state: Option<i32>) -> NameElementChildren {
        NameElementChildren::Image(LayoutImage {
            file: file.to_string(),
            state,
        })
    }

    #[test]
    fn selects_the_element_default_state_image() {
        let element = NameElement {
            name: "background".to_string(),
            defstate: Some(2),
            items: vec![
                layout_image("state-1.png", Some(1)),
                layout_image("state-2.jpg", Some(2)),
            ],
        };

        assert_eq!(
            select_element_image(&element).map(|image| image.file.as_str()),
            Some("state-2.jpg")
        );
    }

    #[test]
    fn prefers_a_stateless_image_when_the_default_state_is_missing() {
        let element = NameElement {
            name: "background".to_string(),
            defstate: Some(2),
            items: vec![
                layout_image("state-1.png", Some(1)),
                layout_image("background.jpg", None),
            ],
        };

        assert_eq!(
            select_element_image(&element).map(|image| image.file.as_str()),
            Some("background.jpg")
        );
    }

    #[test]
    fn crt_target_lays_out_on_square_pixel_320x240_canvas() {
        let view = Bounds {
            x: 0,
            y: 0,
            width: 320,
            height: 240,
        };
        let right_half = Bounds {
            x: 160,
            y: 0,
            width: 160,
            height: 240,
        };
        let dimensions = ImageDimensions::new(
            &view,
            &right_half,
            1.0,
            0,
            0,
            RenderTarget::crt(),
        );

        assert_eq!(dimensions.x, 160);
        assert_eq!(dimensions.y, 0);
        assert_eq!(dimensions.width, 160);
        assert_eq!(dimensions.height, 240);
        assert_eq!(dimensions.canvas_width, 320);
        assert_eq!(dimensions.canvas_height, 240);
    }

    #[test]
    fn crt_expansion_maps_the_complete_composition_to_360_samples() {
        let target = RenderTarget::crt();
        let mut ids = vec![None; target.logical_pixel_count()];
        ids[160] = Some(0x155);

        let expanded = expand_mask_ids(&ids, target);
        assert_eq!(expanded.len(), 360 * 240);
        assert_eq!(expanded[179], None);
        assert_eq!(expanded[180], Some(0x155));
        assert_eq!(expanded[181], None);

        let source = Pixmap::new(320, 240).unwrap();
        let expanded_pixmap = expand_pixmap(&source, target);
        assert_eq!(expanded_pixmap.width(), 360);
        assert_eq!(expanded_pixmap.height(), 240);
    }
}
