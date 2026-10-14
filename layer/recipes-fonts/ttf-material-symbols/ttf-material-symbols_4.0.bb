# Material Symbols Rounded: vrx's icon set. Google's variable icon font,
# about 4,300 symbols with FILL, wght, GRAD and opsz axes, installed once
# system-wide so every applet draws from the same copy through fontconfig
# (vrx_kit's VrxSymbols names the glyphs vrx uses, from its purpose
# table). Apache-2.0.
#
# MSYM_COMMIT and the codepoints checksum are the one pin: `cargo xtask
# glyphs` reads both from this file, and the gate refuses a vendored
# catalogue (vrx_kit/standard/material-symbols.codepoints) that does not
# hash to it, so the font in the image and the names applets compile
# against cannot drift (plan 0013 D5, G033).
#
# SPDX-License-Identifier: MIT

SUMMARY = "Material Symbols Rounded, the vrx icon font"
HOMEPAGE = "https://github.com/google/material-design-icons"
SECTION = "fonts"
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${UNPACKDIR}/LICENSE;md5=175792518e4ac015ab6696d16c4f607e"

MSYM_COMMIT = "49d4db35df873165d6bd6ba09b063c7dafbac2f4"
MSYM_BASE = "https://raw.githubusercontent.com/google/material-design-icons/${MSYM_COMMIT}"

SRC_URI = "\
    ${MSYM_BASE}/variablefont/MaterialSymbolsRounded%5BFILL,GRAD,opsz,wght%5D.ttf;name=font;downloadfilename=MaterialSymbolsRounded-${MSYM_COMMIT}.ttf;unpack=0 \
    ${MSYM_BASE}/variablefont/MaterialSymbolsRounded%5BFILL,GRAD,opsz,wght%5D.codepoints;name=codepoints;downloadfilename=MaterialSymbolsRounded-${MSYM_COMMIT}.codepoints;unpack=0 \
    ${MSYM_BASE}/LICENSE;name=license;downloadfilename=material-design-icons-LICENSE-${MSYM_COMMIT};unpack=0 \
"
SRC_URI[font.sha256sum] = "32e4011709e055596eb8d2dd0f7cb547b47c1d40ac9ecb8fad54f7f7eac202e7"
SRC_URI[codepoints.sha256sum] = "0c9dae3ed678a81549c3be046bc8045335e5f57f2cbe2287360fbf0c2cc1355f"
SRC_URI[license.sha256sum] = "58d1e17ffe5109a7ae296caafcadfdbe6a7d176f0bc4ab01e12a689b0499d8bd"

S = "${UNPACKDIR}"

inherit allarch fontcache

do_unpack[postfuncs] += "msym_name_license"
msym_name_license() {
    cp ${UNPACKDIR}/material-design-icons-LICENSE-${MSYM_COMMIT} ${UNPACKDIR}/LICENSE
}

do_configure[noexec] = "1"
do_compile[noexec] = "1"

do_install() {
    install -d ${D}${datadir}/fonts/truetype
    install -m 0644 ${UNPACKDIR}/MaterialSymbolsRounded-${MSYM_COMMIT}.ttf \
        ${D}${datadir}/fonts/truetype/MaterialSymbolsRounded.ttf
}

FILES:${PN} = "${datadir}/fonts/truetype/MaterialSymbolsRounded.ttf"
FONT_PACKAGES = "${PN}"
