# Zonal icon sources

`zonal-mark.svg` is the supplied base geometry. The export script injects its
`MARK-BEGIN` and `MARK-END` foreground block into the styled app-icon template.
The smaller toolbar mark uses separate, optically adjusted geometry rather than
outlining the filled app-icon paths.

- `zonal-app-icon.template.svg`: color, lighting, glare, and depth treatment.
- `zonal-toolbar.template.svg`: purpose-built outline geometry tuned for 18 pt;
  it keeps only the four outer corners rounded and simplifies the inner shapes.
- `export-icons.sh`: renders the temporary styled SVG and writes only the
  required Xcode asset-catalog outputs.

Run `./Zonal/IconSource/export-icons.sh` after changing a source or template. It
renders the app-icon sizes and toolbar template into `Zonal/Assets.xcassets`.
Do not edit generated asset-catalog contents independently.

## Redistribution

On 2026-10-26 the project owner confirmed ownership or permission to publicly
distribute the supplied icon/base geometry under this project’s MIT license.
The templates and generated icon assets follow that project license.
