import argparse
from PIL import Image, ImageDraw, ImageFont, ImageColor

parser = argparse.ArgumentParser('textimg')
parser.add_argument('-t', '--title', help='Title', required=True)
parser.add_argument('-a', '--artist', help='Artist', required=True)
parser.add_argument('-f', '--font', help='Font', required=True)
parser.add_argument('-c', '--color', help='Color', default='#ffffff')
parser.add_argument('-o', '--output', help='Output file', required=True)
parser.add_argument('-p', '--padding', help='Padding, in pixels')

args = parser.parse_args()

(r, g, b) = ImageColor.getrgb(args.color)
title_fill=(r, g, b, 255)
artist_fill=(r, g, b, 128)

font_size = 100
fnt = ImageFont.truetype(args.font, size=font_size)

height_bbox = fnt.getbbox('!Tlyg')
title_bbox = fnt.getbbox(args.title)
artist_bbox = fnt.getbbox('by ' + args.artist)

title_width = title_bbox[2] - title_bbox[0]
artist_width = artist_bbox[2] - artist_bbox[0]
line_height = height_bbox[3] - height_bbox[1]

padding = args.padding
if padding is None:
    padding = int(font_size / 5)

full_width = max(title_width, artist_width)
full_height = line_height + padding + line_height

out = Image.new("RGBA", (full_width + (2 * padding), full_height + (2 * padding)), (255, 255, 255, 0))
d = ImageDraw.Draw(out)

d.text((0, 0), args.title, font=fnt, fill=title_fill)
d.text((0, line_height + padding), 'by ' + args.artist, font=fnt, fill=artist_fill)
out.save(args.output)
