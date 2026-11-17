"""Make the window's bundled kana font: Noto Sans CJK JP at Regular, cut down
to the kana, the CJK punctuation and the full- and halfwidth forms.

  nix shell --impure --expr 'with import <nixpkgs> {}; python3.withPackages (p: [ p.fonttools ])' \\
    -c python3 kana.py "$(nix build --no-link --print-out-paths nixpkgs#noto-fonts-cjk-sans)/share/fonts/opentype/noto-cjk/NotoSansCJK-VF.otf.ttc" NotoSansJP-Kana.otf

It takes a few minutes: fixing the weight of the variable font is slow."""
import sys
from fontTools.ttLib import TTCollection
from fontTools.varLib import instancer
from fontTools import subset

source, out = sys.argv[1], sys.argv[2]
collection = TTCollection(source)
font = None
for f in collection.fonts:
    names = [n.toUnicode() for n in f['name'].names if n.nameID == 1]
    if any('CJK JP' in n for n in names):
        font = f
        break
assert font is not None, 'no Noto Sans CJK JP in the collection'
if 'fvar' in font:
    font = instancer.instantiateVariableFont(font, {'wght': 400})
ranges = [(0x3000, 0x303F), (0x3040, 0x309F), (0x30A0, 0x30FF), (0x31F0, 0x31FF), (0xFF00, 0xFFEF)]
unicodes = [u for a, b in ranges for u in range(a, b + 1)]
options = subset.Options()
options.layout_features = ['kern', 'liga', 'ccmp', 'locl']
options.drop_tables += ['VORG', 'vhea', 'vmtx', 'VVAR']
options.name_IDs = ['*']
options.name_languages = ['*']
options.notdef_outline = True
options.hinting = False
options.desubroutinize = True
subsetter = subset.Subsetter(options)
subsetter.populate(unicodes=unicodes)
subsetter.subset(font)
font.save(out)
print(out, len(font.getGlyphOrder()), 'glyphs')
