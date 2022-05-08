#include "ReShade.fxh"

uniform float HCRT_INPUT_COLOUR_SPACE              <ui_type = "drag"; ui_min = 0.0; ui_max = 3.0;     ui_step = 1.0;  ui_label = "Input Colour Space: r709 | PAL | NTSC-U | NTSC-J"; > = 0.0;
uniform float HCRT_OUTPUT_COLOUR_SPACE             <ui_type = "drag"; ui_min = 0.0; ui_max = 3.0;     ui_step = 1.0;  ui_label = "Output Colour Space: r709 | sRGB | DCI-P3 | HDR10";> = 3.0;
uniform float HCRT_MAX_NITS                        <ui_type = "drag"; ui_min = 0.0; ui_max = 10000.0; ui_step = 10.0; ui_label = "HDR10: Display's Peak Luminance";> = 1000.0;
uniform float HCRT_PAPER_WHITE_NITS                <ui_type = "drag"; ui_min = 0.0; ui_max = 10000.0; ui_step = 10.0; ui_label = "HDR10: Display's Paper White Luminance";> = 200.0;
uniform float HCRT_EXPAND_GAMUT                    <ui_type = "drag"; ui_min = 0.0; ui_max = 1.0;     ui_step = 1.0;  ui_label = "HDR10: Original/Vivid";> = 1.0;

uniform float HCRT_WHITE_TEMPERATURE               <ui_type = "drag"; ui_min = -5000.0; ui_max = 12000.0;     ui_step = 100.0;  ui_label = "White Temperature Offset (Kelvin)";> = 0.0;
uniform float HCRT_BRIGHTNESS                      <ui_type = "drag"; ui_min = -1.0; ui_max = 1.0;    ui_step = 0.01;  ui_label = "Brightness";> = 0.0;
uniform float HCRT_CONTRAST                        <ui_type = "drag"; ui_min = -1.0; ui_max = 1.0;    ui_step = 0.01;  ui_label = "Contrast";> = 0.0;
uniform float HCRT_SATURATION                      <ui_type = "drag"; ui_min = -1.0; ui_max = 1.0;    ui_step = 0.01;  ui_label = "Saturation";> = 0.0;
uniform float HCRT_GAMMA_IN                        <ui_type = "drag"; ui_min = -1.0; ui_max = 1.0;    ui_step = 0.01;  ui_label = "Gamma In";> = 0.0;
uniform float HCRT_GAMMA_OUT                       <ui_type = "drag"; ui_min = -0.4; ui_max = 0.4;    ui_step = 0.005; ui_label = "SDR: Gamma Out";> = 0.0;

#define COMPAT_TEXTURE(c, d) tex2D(c, d)

////////////////////////////////////////
// REPLACE THESE

float mod(float x, float y)
{
    return x - y * floor(x / y);
}

float2 mod(float2 x, float2 y)
{
    return x - y * floor(x / y);
}

float3 mod(float3 x, float3 y)
{
    return x - y * floor(x / y);
}

float4 mod(float4 x, float4 y)
{
    return x - y * floor(x / y);
}

////////////////////////////////////////

#define kColourSystems  4

#define kD50            5003.0f
#define kD55            5503.0f
#define kD65            6504.0f
#define kD75            7504.0f
#define kD93            9305.0f

static const float3x3 k709_to_XYZ = float3x3(
   0.412391f, 0.357584f, 0.180481f,
   0.212639f, 0.715169f, 0.072192f,
   0.019331f, 0.119195f, 0.950532f);

static const float3x3 kPAL_to_XYZ = float3x3(
   0.430554f, 0.341550f, 0.178352f,
   0.222004f, 0.706655f, 0.071341f,
   0.020182f, 0.129553f, 0.939322f);

static const float3x3 kNTSC_to_XYZ = float3x3(
   0.393521f, 0.365258f, 0.191677f,
   0.212376f, 0.701060f, 0.086564f,
   0.018739f, 0.111934f, 0.958385f);

static const float3x3 kXYZ_to_709 = float3x3(
    3.240970f, -1.537383f, -0.498611f,
   -0.969244f,  1.875968f,  0.041555f,
    0.055630f, -0.203977f,  1.056972f);

static const float3x3 kColourGamut[kColourSystems] = { k709_to_XYZ, kPAL_to_XYZ, kNTSC_to_XYZ, kNTSC_to_XYZ };

static const float kTemperatures[kColourSystems] = { kD65, kD65, kD65, kD93 }; 

  // Values from: http://blenderartists.org/forum/showthread.php?270332-OSL-Goodness&p=2268693&viewfull=1#post2268693   
static const float3x3 kWarmTemperature = float3x3(
   float3(0.0, -2902.1955373783176,   -8257.7997278925690),
	float3(0.0,  1669.5803561666639,    2575.2827530017594),
	float3(1.0,     1.3302673723350029,    1.8993753891711275));

static const float3x3 kCoolTemperature = float3x3(
   float3( 1745.0425298314172,      1216.6168361476490,    -8257.7997278925690),
   float3(-2666.3474220535695,     -2173.1012343082230,     2575.2827530017594),
	float3(    0.55995389139931482,     0.70381203140554553,    1.8993753891711275));

static const float4x4 kCubicBezier = float4x4( 1.0f,  0.0f,  0.0f,  0.0f,
                               -3.0f,  3.0f,  0.0f,  0.0f,
                                3.0f, -6.0f,  3.0f,  0.0f,
                               -1.0f,  3.0f, -3.0f,  1.0f );

float Bezier(const float t0, const float4 control_points)
{
   float4 t = float4(1.0, t0, t0*t0, t0*t0*t0);
   return dot(t, mul(kCubicBezier, control_points));
}

float3 WhiteBalance(float temperature, float3 colour)
{
   float3x3 m;
   
   if(temperature < kD65)
   { 
      m = kWarmTemperature;
   } 
   else
   {
      m = kCoolTemperature;
   }

   const float3 rgb_temperature = lerp(clamp(float3(m[0] / (clamp(temperature, 1000.0f, 40000.0f).xxx + m[1]) + m[2]), 0.0f.xxx, 1.0f.xxx), 1.0f.xxx, smoothstep(1000.0f, 0.0f, temperature));

   float3 result = colour * rgb_temperature;

   result *= dot(colour, float3(0.2126, 0.7152, 0.0722)) / max(dot(result, float3(0.2126, 0.7152, 0.0722)), 1e-5); // Preserve luminance

   return result;
}

float r601ToLinear_1(const float channel)
{
	return (channel >= 0.081f) ? pow((channel + 0.099f) * (1.0f / 1.099f), (1.0f / 0.45f)) : channel * (1.0f / 4.5f);
}

float3 r601ToLinear(const float3 colour)
{
	return float3(r601ToLinear_1(colour.r), r601ToLinear_1(colour.g), r601ToLinear_1(colour.b));
}


float r709ToLinear_1(const float channel)
{
	return (channel >= 0.081f) ? pow((channel + 0.099f) * (1.0f / 1.099f), (1.0f / 0.45f)) : channel * (1.0f / 4.5f);
}

float3 r709ToLinear(const float3 colour)
{
	return float3(r709ToLinear_1(colour.r), r709ToLinear_1(colour.g), r709ToLinear_1(colour.b));
}

// XYZ Yxy transforms found in Dogway's Grade.slang shader

float3 XYZtoYxy(const float3 XYZ)
{
   const float XYZrgb   = XYZ.r + XYZ.g + XYZ.b;
   const float Yxyg     = (XYZrgb <= 0.0f) ? 0.3805f : XYZ.r / XYZrgb;
   const float Yxyb     = (XYZrgb <= 0.0f) ? 0.3769f : XYZ.g / XYZrgb;
   return float3(XYZ.g, Yxyg, Yxyb);
}

float3 YxytoXYZ(const float3 Yxy)
{
   const float Xs    = Yxy.r * (Yxy.g / Yxy.b);
   const float Xsz   = (Yxy.r <= 0.0f) ? 0.0f : 1.0f;
   const float3 XYZ    = float3(Xsz, Xsz, Xsz) * float3(Xs, Yxy.r, (Xs / Yxy.g) - Xs - Yxy.r);
   return XYZ;
}

static const float4 kTopBrightnessControlPoints    = float4(0.0f, 1.0f, 1.0f, 1.0f);
static const float4 kMidBrightnessControlPoints    = float4(0.0f, 1.0f / 3.0f, (1.0f / 3.0f) * 2.0f, 1.0f);
static const float4 kBottomBrightnessControlPoints = float4(0.0f, 0.0f, 0.0f, 1.0f);

float Brightness(const float luminance)
{
   if(HCRT_BRIGHTNESS >= 0.0f)
   {
      return Bezier(luminance, lerp(kMidBrightnessControlPoints, kTopBrightnessControlPoints, HCRT_BRIGHTNESS));
   }
   else
   {
      return Bezier(luminance, lerp(kMidBrightnessControlPoints, kBottomBrightnessControlPoints, abs(HCRT_BRIGHTNESS)));
   }
}

static const float4 kTopContrastControlPoints    = float4(0.0f, 0.0f, 1.0f, 1.0f);
static const float4 kMidContrastControlPoints    = float4(0.0f, 1.0f / 3.0f, (1.0f / 3.0f) * 2.0f, 1.0f);
static const float4 kBottomContrastControlPoints = float4(0.0f, 1.0f, 0.0f, 1.0f);

float Contrast(const float luminance)
{
   if(HCRT_CONTRAST >= 0.0f)
   {
      return Bezier(luminance, lerp(kMidContrastControlPoints, kTopContrastControlPoints, HCRT_CONTRAST));
   }
   else
   {
      return Bezier(luminance, lerp(kMidContrastControlPoints, kBottomContrastControlPoints, abs(HCRT_CONTRAST)));
   }
}

float3 Saturation(const float3 colour)
{
   const float luma           = dot(colour, float3(0.2125, 0.7154, 0.0721));
   const float saturation     = 0.5f + HCRT_SATURATION * 0.5f;

   return clamp(lerp(luma.xxx, colour, saturation.xxx * 2.0f), 0.0f.xxx, 1.0f.xxx);
}

float3 BrightnessContrastSaturation(const float3 xyz)
{
   const float3 Yxy              = XYZtoYxy(xyz);
   const float Y_gamma           = clamp(pow(Yxy.x, 1.0f / 2.4f), 0.0f, 1.0f);
   
   const float Y_brightness      = Brightness(Y_gamma);

   const float Y_contrast        = Contrast(Y_brightness);

   const float3 contrast_linear  = float3(pow(Y_contrast, 2.4f), Yxy.y, Yxy.z);
   const float3 contrast         = clamp(mul(kXYZ_to_709, YxytoXYZ(contrast_linear)), 0.0f, 1.0f);

   const float3 saturation       = Saturation(contrast);

   return saturation;
}

float3 ColourGrade(const float3 colour)
{
   const uint colour_system      = uint(HCRT_INPUT_COLOUR_SPACE);

   const float3 white_point      = WhiteBalance(kTemperatures[colour_system] + HCRT_WHITE_TEMPERATURE, colour);

   const float3 _linear          = pow(white_point, ((1.0f / 0.45f) + HCRT_GAMMA_IN).xxx);

   const float3 xyz              = mul(kColourGamut[colour_system], _linear);

   const float3 graded           = BrightnessContrastSaturation(xyz); 

   return graded;
}

////////////////////////////////////////

#define kMaxNitsFor2084     10000.0f
#define kEpsilon            0.0001f

float3 InverseTonemap(const float3 sdr_linear, const float max_nits, const float paper_white_nits)
{
   const float luma                 = dot(sdr_linear, float3(0.2126, 0.7152, 0.0722));  // Rec BT.709 luma coefficients - https://en.wikipedia.org/wiki/Luma_(video) 

   // Inverse reinhard tonemap 
   const float max_value            = (max_nits / paper_white_nits) + kEpsilon;
   const float elbow                = max_value / (max_value - 1.0f);                          
   const float offset               = 1.0f - ((0.5f * elbow) / (elbow - 0.5f));              
   
   const float hdr_luma_inv_tonemap = offset + ((luma * elbow) / (elbow - luma));
   const float sdr_luma_inv_tonemap = luma / ((1.0f + kEpsilon) - luma);                     // Convert the srd < 0.5 to 0.0 -> 1.0 range 

   const float luma_inv_tonemap     = (luma > 0.5f) ? hdr_luma_inv_tonemap : sdr_luma_inv_tonemap;
   const float3 hdr                   = sdr_linear / (luma + kEpsilon) * luma_inv_tonemap;

   return hdr;
}

float3 InverseTonemapConditional(const float3 _linear)
{
   if(HCRT_OUTPUT_COLOUR_SPACE < 3.0f)
   {
      return _linear;
   }
   else
   {
      return InverseTonemap(_linear, HCRT_MAX_NITS, HCRT_PAPER_WHITE_NITS);
   }
}

////////////////////////////////////////

//#define kMaxNitsFor2084     10000.0f

static const float3x3 k709_to_2020 = float3x3 (
   0.6274040f, 0.3292820f, 0.0433136f,
   0.0690970f, 0.9195400f, 0.0113612f,
   0.0163916f, 0.0880132f, 0.8955950f);

// START Converted from (Copyright (c) Microsoft Corporation - Licensed under the MIT License.)  https://github.com/microsoft/Xbox-ATG-Samples/tree/master/Kits/ATGTK/HDR 
static const float3x3 kExpanded709_to_2020 = float3x3 (
    0.6274040f,  0.3292820f, 0.0433136f,
    0.0457456f,  0.941777f,  0.0124772f,
   -0.00121055f, 0.0176041f, 0.983607f);

static const float3x3 k2020Gamuts[2] = { k709_to_2020, kExpanded709_to_2020 };

float3 LinearToST2084(float3 normalizedLinearValue)
{
   //float3 ST2084 = pow((0.8359375f + 18.8515625f * pow(abs(normalizedLinearValue), float3(0.1593017578f))) / (1.0f + 18.6875f * pow(abs(normalizedLinearValue), float3(0.1593017578f))), float3(78.84375f));
   float3 ST2084 = pow((0.8359375f.xxx + (pow(abs(normalizedLinearValue), 0.1593017578125f.xxx) * 18.8515625f)) / (1.0f.xxx + (pow(abs(normalizedLinearValue), 0.1593017578125f.xxx) * 18.6875f)), 78.84375f.xxx);
   return ST2084;  // Don't clamp between [0..1], so we can still perform operations on scene values higher than 10,000 nits
}
// END Converted from (Copyright (c) Microsoft Corporation - Licensed under the MIT License.)  https://github.com/microsoft/Xbox-ATG-Samples/tree/master/Kits/ATGTK/HDR 

//Convert into HDR10
float3 Hdr10(float3 hdr_linear, float paper_white_nits, float expand_gamut)
{
   float3 rec2020       = mul(k2020Gamuts[uint(expand_gamut)], hdr_linear);
   float3 linearColour  = rec2020 * (paper_white_nits / kMaxNitsFor2084);
   float3 hdr10         = LinearToST2084(linearColour);

   return hdr10;
}

////////////////////////////////////////

static const float3x3 k709_to_XYZ = float3x3(
   0.412391f, 0.357584f, 0.180481f,
   0.212639f, 0.715169f, 0.072192f,
   0.019331f, 0.119195f, 0.950532f);

static const float3x3 kXYZ_to_DCIP3 = float3x3 (
    2.4934969119f, -0.9313836179f, -0.4027107845f,
   -0.8294889696f,  1.7626640603f,  0.0236246858f,
    0.0358458302f, -0.0761723893f,  0.9568845240f);

float LinearTosRGB_1(const float channel)
{
	return (channel > 0.0031308f) ? (1.055f * pow(channel, (1.0f / 2.4f) + HCRT_GAMMA_OUT)) - 0.055f : channel * 12.92f;
}

float3 LinearTosRGB(const float3 colour)
{
	return float3(LinearTosRGB_1(colour.r), LinearTosRGB_1(colour.g), LinearTosRGB_1(colour.b));
}

float LinearTo709_1(const float channel)
{
	return (channel >= 0.018f) ? pow(channel * 1.099f, 0.45f + HCRT_GAMMA_OUT) - 0.099f : channel * 4.5f;
}

float3 LinearTo709(const float3 colour)
{
	return float3(LinearTo709_1(colour.r), LinearTo709_1(colour.g), LinearTo709_1(colour.b));
}

float3 LinearToDCIP3(const float3 colour)
{
	return clamp(pow(colour, (1.0f / 2.6f).xxx  + HCRT_GAMMA_OUT.xxx), 0.0f.xxx, 1.0f.xxx);
}

float3 GammaCorrect(const float3 scanline_colour)
{
    if (HCRT_OUTPUT_COLOUR_SPACE == 3.0f)
    {
        return Hdr10(scanline_colour, HCRT_PAPER_WHITE_NITS, HCRT_EXPAND_GAMUT);
    }
    else if(HCRT_OUTPUT_COLOUR_SPACE == 0.0f)
    {
        return LinearTo709(scanline_colour);
    }
    else if(HCRT_OUTPUT_COLOUR_SPACE == 1.0f)
    {
        return LinearTosRGB(scanline_colour);
    }
    else
    {
        const float3 dcip3_colour = mul(kXYZ_to_DCIP3, mul(k709_to_XYZ, scanline_colour)); 
        return LinearToDCIP3(dcip3_colour);
    }
}

////////////////////////////////////////

void AutoHDR(float4 vpos : SV_Position, float2 texcoord : TEXCOORD, out float4 fragment : SV_Target0)
{
   float3 source = COMPAT_TEXTURE(ReShade::BackBuffer, texcoord).rgb;

   const float3 colour   = ColourGrade(source);

   const float3 hdr_colour = InverseTonemapConditional(colour);

   const float3 hdr10 = GammaCorrect(hdr_colour);

   fragment = float4(hdr10, 1.0f);
}

technique AutoHDR
{
	pass { VertexShader = PostProcessVS; PixelShader = AutoHDR; }
}