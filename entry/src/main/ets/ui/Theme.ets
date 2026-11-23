// 首页与设置共用可切换主题，终端固定使用深色背景与文字。
export const APP_FONT = 'Maple Mono';
export const TERMINAL_BACKGROUND = '#10131e';
export const TERMINAL_SURFACE = '#1b2031';
export const TERMINAL_TEXT = '#f1f1fc';
export const TERMINAL_MUTED = '#a9b3d0';

export interface ThemePalette {
  id: string;
  name: string;
  deep: string;
  action: string;
  ink: string;
  glow: string;
  light: string;
  tint: string;
  darkTint: string;
}

export const PALETTES: ThemePalette[] = [
  { id: 'indigo', name: '靛紫', deep: '#2c248f', action: '#4c3cdd', ink: '#4437d0', glow: '#9681ff',
    light: '#b6a9ff', tint: '#eeecff', darkTint: '#312852' },
  { id: 'ocean', name: '海蓝', deep: '#063875', action: '#115bbc', ink: '#1051a5', glow: '#66c6ff',
    light: '#9ed0ff', tint: '#e7f2ff', darkTint: '#1f3659' },
  { id: 'pine', name: '松绿', deep: '#073e34', action: '#0d6b53', ink: '#08644d', glow: '#49e0a9',
    light: '#7be4ba', tint: '#def5ed', darkTint: '#1d3d34' },
  { id: 'amber', name: '琥珀', deep: '#74300d', action: '#a14814', ink: '#97420e', glow: '#ffb06b',
    light: '#ffc38e', tint: '#fff0e1', darkTint: '#4a2d23' }
];

export interface NerveColors {
  palette: ThemePalette;
  background: string;
  surface: string;
  foreground: string;
  muted: string;
  line: string;
  accent: string;
  tint: string;
  error: string;
  warning: string;
  warningSurface: string;
}

// 按主题色和深浅外观统一生成页面配色，未知主题回退到靛紫。
export function nerveColors(paletteId: string, dark: boolean): NerveColors {
  const palette = PALETTES.find((item: ThemePalette): boolean => item.id === paletteId) ?? PALETTES[0];
  return {
    palette,
    background: dark ? '#151725' : '#f6f7fb',
    surface: dark ? '#1e2132' : '#ffffff',
    foreground: dark ? '#f0f0ff' : '#182036',
    muted: dark ? '#a6aec8' : '#525f76',
    line: dark ? '#303449' : '#e5e8f1',
    accent: dark ? palette.light : palette.ink,
    tint: dark ? palette.darkTint : palette.tint,
    error: dark ? '#ffb7a9' : '#a52928',
    warning: dark ? '#ffcc89' : '#8a5114',
    warningSurface: dark ? '#3d2c25' : '#fff0db'
  };
}
