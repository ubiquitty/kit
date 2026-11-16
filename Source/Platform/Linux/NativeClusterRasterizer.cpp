// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Linux/NativeClusterRasterizer.h"

#include "Core/CellContent.h"
#include "Core/Unicode/Width.h"

#include <algorithm>
#include <array>
#include <cstdio>
#include <utility>
#include <vector>

#include <fontconfig/fontconfig.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_MULTIPLE_MASTERS_H
#include <cairo/cairo-ft.h>
#include <fontconfig/fcfreetype.h>
#include <pango/pangocairo.h>
#include <pango/pangofc-font.h>
#include <pango/pangofc-fontmap.h>

namespace Ubiquitty::Linux {

namespace {

// A cached scaled font owns an identity CTM. Install its font facts separately
// so Cairo derives a scaled font for the complete cluster's drawing transform.
void setNativeFontForTransform(cairo_t* painter, cairo_scaled_font_t* font)
{
    cairo_matrix_t matrix;
    cairo_scaled_font_get_font_matrix(font, &matrix);
    cairo_set_font_face(painter, cairo_scaled_font_get_font_face(font));
    cairo_set_font_matrix(painter, &matrix);
    cairo_font_options_t* options = cairo_font_options_create();
    cairo_scaled_font_get_font_options(font, options);
    cairo_set_font_options(painter, options);
    cairo_font_options_destroy(options);
}

} // namespace

struct NativeClusterRasterizer::Impl {
    FcConfig* source { FcConfigReference(FcConfigGetCurrent()) };
    FcConfig* configuration { FcConfigCreate() };
    PangoFontMap* map { pango_cairo_font_map_new() };
    PangoContext* context { nullptr };
    cairo_surface_t* surface { nullptr };
    int surfaceWidth { 0 };
    int surfaceHeight { 0 };
    struct FontAlias {
        std::string file;
        long index;
        std::string family;
    };
    std::vector<FontAlias> aliases;
    struct ScaledFontDeleter {
        void operator()(cairo_scaled_font_t* font) const { cairo_scaled_font_destroy(font); }
    };
    struct ScaledFont {
        std::string file;
        long index;
        double em;
        double horizontalScale;
        std::string variations;
        std::unique_ptr<cairo_scaled_font_t, ScaledFontDeleter> font;
    };
    std::vector<ScaledFont> scaledFonts;

    ~Impl()
    {
        scaledFonts.clear();
        if (surface)
            cairo_surface_destroy(surface);
        if (context)
            g_object_unref(context);
        g_object_unref(map);
        FcConfigDestroy(configuration);
        FcConfigDestroy(source);
    }

    static void substitute(FcPattern* pattern, gpointer data)
    {
        // Preserve the desktop's native fallback ordering while the private
        // font set also exposes exact-file aliases for Core's resolved faces.
        FcConfigSubstitute(static_cast<FcConfig*>(data), pattern, FcMatchPattern);
        FcDefaultSubstitute(pattern);
    }

    bool initialize(const std::string& firstFile)
    {
        if (context)
            return true;
        if (!configuration || !map || !FcConfigAppFontAddFile(configuration, reinterpret_cast<const FcChar8*>(firstFile.c_str())))
            return false;
        FcFontSet* destination = FcConfigGetFonts(configuration, FcSetApplication);
        if (!destination)
            return false;
        for (auto set : { FcSetSystem, FcSetApplication }) {
            if (const FcFontSet* fonts = FcConfigGetFonts(source, set)) {
                for (int index = 0; index < fonts->nfont; ++index)
                    FcFontSetAdd(destination, FcPatternDuplicate(fonts->fonts[index]));
            }
        }
        pango_fc_font_map_set_config(PANGO_FC_FONT_MAP(map), configuration);
        pango_fc_font_map_set_default_substitute(PANGO_FC_FONT_MAP(map), substitute, source, nullptr);
        context = pango_font_map_create_context(map);
        pango_context_set_base_dir(context, PANGO_DIRECTION_LTR);
        pango_context_set_round_glyph_positions(context, TRUE);
        pango_cairo_context_set_resolution(context, 96.0);
        cairo_font_options_t* options = cairo_font_options_create();
        cairo_font_options_set_antialias(options, CAIRO_ANTIALIAS_GRAY);
        cairo_font_options_set_hint_style(options, CAIRO_HINT_STYLE_NONE);
        cairo_font_options_set_hint_metrics(options, CAIRO_HINT_METRICS_ON);
        pango_cairo_context_set_font_options(context, options);
        cairo_font_options_destroy(options);
        return true;
    }

    std::string aliasFor(const NativeClusterFont& font)
    {
        const long index = font.face->face_index;
        for (const auto& alias : aliases) {
            if (alias.file == font.file && alias.index == index)
                return alias.family;
        }
        int count = 0;
        FcPattern* pattern = FcFreeTypeQuery(reinterpret_cast<const FcChar8*>(font.file.c_str()), static_cast<unsigned>(index), nullptr, &count);
        if (!pattern)
            return {};
        const std::string family = "Ubiquitty Native Face " + std::to_string(aliases.size());
        FcPatternDel(pattern, FC_FAMILY);
        FcPatternAddString(pattern, FC_FAMILY, reinterpret_cast<const FcChar8*>(family.c_str()));
        FcFontSet* fonts = FcConfigGetFonts(configuration, FcSetApplication);
        if (!fonts || !FcFontSetAdd(fonts, pattern)) {
            FcPatternDestroy(pattern);
            return {};
        }
        aliases.push_back({ font.file, index, family });
        pango_fc_font_map_config_changed(PANGO_FC_FONT_MAP(map));
        return family;
    }

    std::string variationsFor(const NativeClusterFont& font)
    {
        std::string variations;
        FT_MM_Var* axes = nullptr;
        if (FT_Get_MM_Var(font.face, &axes) == 0 && axes) {
            std::vector<FT_Fixed> values(axes->num_axis);
            if (FT_Get_Var_Design_Coordinates(font.face, axes->num_axis, values.data()) == 0) {
                for (unsigned index = 0; index < axes->num_axis; ++index) {
                    std::array<char, 64> encoded {};
                    const auto tag = axes->axis[index].tag;
                    std::snprintf(encoded.data(), encoded.size(), "%c%c%c%c=%.8g", static_cast<char>(tag >> 24), static_cast<char>(tag >> 16),
                        static_cast<char>(tag >> 8), static_cast<char>(tag), values[index] / 65536.0);
                    if (!variations.empty())
                        variations += ',';
                    variations += encoded.data();
                }
            }
            FT_Done_MM_Var(font.face->glyph->library, axes);
        }
        return variations;
    }

    cairo_scaled_font_t* scaledFontFor(const NativeClusterFont& font)
    {
        if (!font.face || font.file.empty())
            return nullptr;
        const double em = font.emSize > 0 ? font.emSize : FT_MulFix(font.face->units_per_EM, font.face->size->metrics.y_scale) / 64.0;
        const auto variations = variationsFor(font);
        for (const auto& cached : scaledFonts)
            if (cached.file == font.file && cached.index == font.face->face_index && cached.em == em && cached.horizontalScale == font.horizontalScale && cached.variations == variations)
                return cached.font.get();
        int count = 0;
        FcPattern* pattern = FcFreeTypeQuery(reinterpret_cast<const FcChar8*>(font.file.c_str()), static_cast<unsigned>(font.face->face_index), nullptr, &count);
        if (!pattern)
            return nullptr;
        FcPatternDel(pattern, FC_HINTING);
        FcPatternAddBool(pattern, FC_HINTING, FcFalse);
        FcPatternDel(pattern, FC_HINT_STYLE);
        FcPatternAddInteger(pattern, FC_HINT_STYLE, FC_HINT_NONE);
        FcPatternDel(pattern, FC_RGBA);
        FcPatternAddInteger(pattern, FC_RGBA, FC_RGBA_NONE);
        if (!variations.empty()) {
            FcPatternDel(pattern, FC_FONT_VARIATIONS);
            FcPatternAddString(pattern, FC_FONT_VARIATIONS, reinterpret_cast<const FcChar8*>(variations.c_str()));
        }
        FcPatternDel(pattern, FC_FT_FACE);
        cairo_font_face_t* face = cairo_ft_font_face_create_for_pattern(pattern);
        FcPatternDestroy(pattern);
        cairo_matrix_t matrix, identity;
        cairo_matrix_init_scale(&matrix, em * font.horizontalScale, em);
        cairo_matrix_init_identity(&identity);
        cairo_font_options_t* options = cairo_font_options_create();
        cairo_font_options_set_antialias(options, CAIRO_ANTIALIAS_GRAY);
        cairo_font_options_set_hint_style(options, CAIRO_HINT_STYLE_NONE);
        cairo_font_options_set_hint_metrics(options, CAIRO_HINT_METRICS_ON);
        cairo_scaled_font_t* scaled = cairo_scaled_font_create(face, &matrix, &identity, options);
        cairo_font_options_destroy(options);
        cairo_font_face_destroy(face);
        if (cairo_scaled_font_status(scaled) != CAIRO_STATUS_SUCCESS) {
            cairo_scaled_font_destroy(scaled);
            return nullptr;
        }
        // Font sets are immutable, but sized masters can request many ems.
        // Bound native descriptors independently of adversarial input sizes.
        if (scaledFonts.size() == 32) {
            scaledFonts.erase(scaledFonts.begin());
        }
        scaledFonts.push_back({ font.file, font.face->face_index, em, font.horizontalScale, variations, std::unique_ptr<cairo_scaled_font_t, ScaledFontDeleter>(scaled) });
        return scaled;
    }

    PangoFontDescription* descriptionFor(const NativeClusterFont& font)
    {
        if (!font.face || font.file.empty())
            return nullptr;
        const auto alias = aliasFor(font);
        if (alias.empty())
            return nullptr;
        auto* description = pango_font_description_new();
        pango_font_description_set_family(description, alias.c_str());
        const double em = font.emSize > 0 ? font.emSize : FT_MulFix(font.face->units_per_EM, font.face->size->metrics.y_scale) / 64.0;
        pango_font_description_set_absolute_size(description, em * PANGO_SCALE);
        pango_font_description_set_weight(description, Rendering::isBold(font.style) ? PANGO_WEIGHT_BOLD : PANGO_WEIGHT_NORMAL);
        pango_font_description_set_style(description, Rendering::isItalic(font.style) ? PANGO_STYLE_ITALIC : PANGO_STYLE_NORMAL);
        const auto variations = variationsFor(font);
        if (!variations.empty())
            pango_font_description_set_variations(description, variations.c_str());
        return description;
    }
};

NativeClusterRasterizer::NativeClusterRasterizer()
    : m_impl(std::make_unique<Impl>())
{
}

NativeClusterRasterizer::~NativeClusterRasterizer() = default;

bool NativeClusterRasterizer::glyphBounds(const NativeClusterFont& font, std::uint32_t glyph, NativeGlyphBounds& bounds)
{
    auto* scaled = m_impl->scaledFontFor(font);
    if (!scaled)
        return false;
    const cairo_glyph_t native { glyph, 0, 0 };
    cairo_text_extents_t extents;
    cairo_scaled_font_glyph_extents(scaled, &native, 1, &extents);
    bounds = { extents.x_bearing, extents.y_bearing, extents.width, extents.height };
    return cairo_scaled_font_status(scaled) == CAIRO_STATUS_SUCCESS;
}

bool NativeClusterRasterizer::drawGlyphs(std::span<const NativePositionedGlyph> glyphs, const NativeClusterFont& font,
    int width, int height, std::span<std::uint8_t> coverage,
    const Rendering::ClusterRasterBounds* bounds, double advanceLeft, double advanceRight)
{
    if (glyphs.empty() || width <= 0 || height <= 0 || coverage.size() != static_cast<std::size_t>(width) * height)
        return false;
    auto* scaled = m_impl->scaledFontFor(font);
    if (!scaled)
        return false;
    if (!m_impl->surface || m_impl->surfaceWidth != width || m_impl->surfaceHeight != height) {
        if (m_impl->surface)
            cairo_surface_destroy(m_impl->surface);
        m_impl->surface = cairo_image_surface_create(CAIRO_FORMAT_A8, width, height);
        m_impl->surfaceWidth = width;
        m_impl->surfaceHeight = height;
    }
    if (cairo_surface_status(m_impl->surface) != CAIRO_STATUS_SUCCESS)
        return false;
    std::unique_ptr<cairo_t, decltype(&cairo_destroy)> painter(cairo_create(m_impl->surface), cairo_destroy);
    cairo_set_operator(painter.get(), CAIRO_OPERATOR_CLEAR);
    cairo_paint(painter.get());
    cairo_set_operator(painter.get(), CAIRO_OPERATOR_OVER);
    cairo_set_source_rgba(painter.get(), 1, 1, 1, 1);
    std::vector<cairo_glyph_t> native;
    native.reserve(glyphs.size());
    for (const auto& glyph : glyphs)
        native.push_back({ glyph.glyph, glyph.x, glyph.y });
    const bool shouldFit = bounds && std::abs(advanceRight - advanceLeft) > bounds->width;
    if (shouldFit) {
        cairo_text_extents_t ink;
        cairo_scaled_font_glyph_extents(scaled, native.data(), static_cast<int>(native.size()), &ink);
        const double inkLeft = native.front().x + ink.x_bearing;
        const auto fit = Rendering::fitClusterHorizontal(std::min({ advanceLeft, advanceRight, inkLeft }),
            std::max({ advanceLeft, advanceRight, inkLeft + ink.width }), *bounds);
        cairo_rectangle(painter.get(), bounds->left, 0, bounds->width, height);
        cairo_clip(painter.get());
        cairo_translate(painter.get(), fit.translationX, 0);
        cairo_scale(painter.get(), fit.scaleX, 1);
    }
    if (shouldFit)
        setNativeFontForTransform(painter.get(), scaled);
    else
        cairo_set_scaled_font(painter.get(), scaled);
    cairo_show_glyphs(painter.get(), native.data(), static_cast<int>(native.size()));
    if (cairo_status(painter.get()) != CAIRO_STATUS_SUCCESS)
        return false;
    cairo_surface_flush(m_impl->surface);
    for (int row = 0; row < height; ++row)
        std::copy_n(cairo_image_surface_get_data(m_impl->surface) + row * cairo_image_surface_get_stride(m_impl->surface), width,
            coverage.data() + static_cast<std::size_t>(row) * width);
    return true;
}

bool NativeClusterRasterizer::draw(std::span<const std::uint32_t> codePoints, const NativeClusterFont& base,
    ResolveRun resolve, void* callbackContext, std::string_view features, double penX, double baseline,
    int width, int height, std::span<std::uint8_t> coverage, const Rendering::ClusterRasterBounds* bounds)
{
    if (codePoints.empty() || codePoints.size() > clusterPoolMaximumCodePoints || !base.face || base.file.empty()
        || !resolve || width <= 0 || height <= 0 || coverage.size() != static_cast<std::size_t>(width) * height
        || !m_impl->initialize(base.file))
        return false;
    std::string text;
    std::vector<unsigned> offsets;
    std::vector<std::uint32_t> visible;
    for (const auto codePoint : codePoints) {
        if (Unicode::Width::isInvisibleFormat(codePoint))
            continue;
        offsets.push_back(static_cast<unsigned>(text.size()));
        visible.push_back(codePoint);
        std::array<char, 7> encoded {};
        const int length = g_unichar_to_utf8(codePoint, encoded.data());
        text.append(encoded.data(), static_cast<std::size_t>(length));
    }
    offsets.push_back(static_cast<unsigned>(text.size()));
    if (visible.empty())
        return false;
    using Description = std::unique_ptr<PangoFontDescription, decltype(&pango_font_description_free)>;
    Description baseDescription(m_impl->descriptionFor(base), pango_font_description_free);
    if (!baseDescription)
        return false;
    const auto releaseLayout = [](PangoLayout* layout) { g_object_unref(layout); };
    std::unique_ptr<PangoLayout, decltype(releaseLayout)> layout(pango_layout_new(m_impl->context), releaseLayout);
    pango_layout_set_font_description(layout.get(), baseDescription.get());
    pango_layout_set_auto_dir(layout.get(), FALSE);
    std::unique_ptr<PangoAttrList, decltype(&pango_attr_list_unref)> attributes(pango_attr_list_new(), pango_attr_list_unref);
    const std::string featureString(features);
    pango_attr_list_insert(attributes.get(), pango_attr_font_features_new(featureString.c_str()));
    pango_layout_set_attributes(layout.get(), attributes.get());
    pango_layout_set_text(layout.get(), text.data(), static_cast<int>(text.size()));
    PangoLayoutLine* line = pango_layout_get_line_readonly(layout.get(), 0);
    if (!line)
        return false;
    struct FallbackRun {
        unsigned first;
        unsigned end;
    };
    std::vector<FallbackRun> runs;
    struct ResolvedRun {
        unsigned first;
        unsigned end;
        NativeClusterFont font;
    };
    std::vector<ResolvedRun> resolvedRuns;

    for (auto* node = line->runs; node; node = node->next) {
        const auto* run = static_cast<const PangoLayoutRun*>(node->data);
        FcChar8* file = nullptr;
        int index = 0;
        FcPattern* pattern = pango_fc_font_get_pattern(PANGO_FC_FONT(run->item->analysis.font));
        FcPatternGetString(pattern, FC_FILE, 0, &file);
        FcPatternGetInteger(pattern, FC_INDEX, 0, &index);
        if (!file || base.file != reinterpret_cast<const char*>(file) || (index & 0xffff) != (base.face->face_index & 0xffff))
            runs.push_back({ static_cast<unsigned>(run->item->offset), static_cast<unsigned>(run->item->offset + run->item->length) });
    }
    // The first pass gives native cluster boundaries. Resolve each complete
    // fallback run through Core, then shape once with that face and optical size.
    // Disallow further substitution: a native mask must not bypass Core routes.
    // Layout retains the first list and skips invalidation for that same pointer;
    // mutate a copy so reused cached fallback faces still trigger reshaping.
    attributes.reset(pango_attr_list_copy(attributes.get()));
    pango_attr_list_insert(attributes.get(), pango_attr_fallback_new(FALSE));
    for (const auto run : runs) {
        const auto first = std::lower_bound(offsets.begin(), offsets.end(), run.first) - offsets.begin();
        const auto end = std::lower_bound(offsets.begin(), offsets.end(), run.end) - offsets.begin();
        const auto points = std::span(visible).subspan(static_cast<std::size_t>(first), static_cast<std::size_t>(end - first));
        const auto font = resolve(callbackContext, points, base.style);
        resolvedRuns.push_back({ run.first, run.end, font });
        Description description(m_impl->descriptionFor(font), pango_font_description_free);
        if (!description)
            return false;
        PangoAttribute* attribute = pango_attr_font_desc_new(description.get());
        attribute->start_index = run.first;
        attribute->end_index = run.end;
        // Adjacent native runs may resolve to the same Core face. Let Pango
        // merge equal descriptions so an earlier fallback boundary cannot
        // break mark-to-mark positioning after routing has unified the runs.
        pango_attr_list_change(attributes.get(), attribute);
    }
    pango_layout_set_attributes(layout.get(), attributes.get());
    line = pango_layout_get_line_readonly(layout.get(), 0);
    if (!line)
        return false;
    if (!m_impl->surface || m_impl->surfaceWidth != width || m_impl->surfaceHeight != height) {
        if (m_impl->surface)
            cairo_surface_destroy(m_impl->surface);
        m_impl->surface = cairo_image_surface_create(CAIRO_FORMAT_A8, width, height);
        m_impl->surfaceWidth = width;
        m_impl->surfaceHeight = height;
    }
    if (cairo_surface_status(m_impl->surface) != CAIRO_STATUS_SUCCESS)
        return false;
    std::unique_ptr<cairo_t, decltype(&cairo_destroy)> painter(cairo_create(m_impl->surface), cairo_destroy);
    cairo_set_operator(painter.get(), CAIRO_OPERATOR_CLEAR);
    cairo_paint(painter.get());
    cairo_set_operator(painter.get(), CAIRO_OPERATOR_OVER);
    cairo_set_source_rgba(painter.get(), 1, 1, 1, 1);
    // Pango owns glyph selection and positioning. Its description stores
    // sizes in 1/1024 units, so using its rounded pixel description for the
    // mask would discard the original point/DPI matrix. Draw the resolved
    // native glyph IDs with the exact Core-selected em instead.
    struct PositionedRun {
        cairo_scaled_font_t* font;
        std::vector<cairo_glyph_t> glyphs;
    };
    std::vector<PositionedRun> positionedRuns;
    double x = penX;
    double inkLeft = penX;
    double inkRight = penX;
    for (auto* node = line->runs; node; node = node->next) {
        const auto* run = static_cast<const PangoLayoutRun*>(node->data);
        const NativeClusterFont* font = &base;
        for (const auto& resolved : resolvedRuns) {
            if (static_cast<unsigned>(run->item->offset) >= resolved.first
                && static_cast<unsigned>(run->item->offset) < resolved.end) {
                font = &resolved.font;
                break;
            }
        }
        auto* scaled = m_impl->scaledFontFor(*font);
        if (!scaled)
            return false;
        std::vector<cairo_glyph_t> glyphs;
        glyphs.reserve(static_cast<std::size_t>(run->glyphs->num_glyphs));
        for (int index = 0; index < run->glyphs->num_glyphs; ++index) {
            const auto& glyph = run->glyphs->glyphs[index];
            if (glyph.glyph != PANGO_GLYPH_EMPTY) {
                if (glyph.glyph & PANGO_GLYPH_UNKNOWN_FLAG)
                    return false;
                glyphs.push_back({ glyph.glyph, x + glyph.geometry.x_offset / static_cast<double>(PANGO_SCALE),
                    baseline + glyph.geometry.y_offset / static_cast<double>(PANGO_SCALE) });
            }
            x += glyph.geometry.width / static_cast<double>(PANGO_SCALE);
        }
        if (bounds && !glyphs.empty()) {
            cairo_text_extents_t ink;
            cairo_scaled_font_glyph_extents(scaled, glyphs.data(), static_cast<int>(glyphs.size()), &ink);
            const double runLeft = glyphs.front().x + ink.x_bearing;
            inkLeft = std::min(inkLeft, runLeft);
            inkRight = std::max(inkRight, runLeft + ink.width);
        }
        if (bounds)
            positionedRuns.push_back({ scaled, std::move(glyphs) });
        else {
            cairo_set_scaled_font(painter.get(), scaled);
            cairo_show_glyphs(painter.get(), glyphs.data(), static_cast<int>(glyphs.size()));
        }
    }
    const bool shouldFit = bounds && std::abs(x - penX) > bounds->width;
    if (shouldFit) {
        const auto fit = Rendering::fitClusterHorizontal(std::min(inkLeft, x), std::max(inkRight, x), *bounds);
        cairo_rectangle(painter.get(), bounds->left, 0, bounds->width, height);
        cairo_clip(painter.get());
        cairo_translate(painter.get(), fit.translationX, 0);
        cairo_scale(painter.get(), fit.scaleX, 1);
    }
    for (const auto& run : positionedRuns) {
        if (shouldFit)
            setNativeFontForTransform(painter.get(), run.font);
        else
            cairo_set_scaled_font(painter.get(), run.font);
        cairo_show_glyphs(painter.get(), run.glyphs.data(), static_cast<int>(run.glyphs.size()));
    }
    if (cairo_status(painter.get()) != CAIRO_STATUS_SUCCESS)
        return false;
    cairo_surface_flush(m_impl->surface);
    for (int row = 0; row < height; ++row)
        std::copy_n(cairo_image_surface_get_data(m_impl->surface) + row * cairo_image_surface_get_stride(m_impl->surface), width,
            coverage.data() + static_cast<std::size_t>(row) * width);
    return true;
}

} // namespace Ubiquitty::Linux
