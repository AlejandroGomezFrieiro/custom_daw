# Pictures in the terminal

<!-- tags: graphics kitty-graphics strips -->

A view that paints for the graphical window (`paint`, see
[The graphical frontend](window.md)) shows the same pixels in a
terminal that shows images. An example is the score of `:notation`.

## What paw asks the terminal

At the start, paw asks the terminal:

- what it is (XTVERSION).
- its colors (`OSC 10` and `11`).
- the size of a cell in pixels.
- if it shows images with the kitty graphics protocol, and how it takes them: through shared memory, a temporary file, or in the escape sequences.
- if it reports the pointer in pixels (mode 1016).

The log gives the result, in a line that starts with `terminal:`.

## Strips

A picture is a **strip**: a rectangle of cells that a view keeps for
pixels when it draws (`buf:strip`, see [Extensions](../extensions.md)). A
strip has a key of its own. So a view can have several strips, and the
same view in two windows (`:vs`) has a strip in each, separate.

| View | Strips |
| --- | --- |
| Score (`:notation`) | one strip over its window |
| Curve editor (`gC`) | the plot |
| Piano roll | the controller strip (the pitch wheel and the controllers) |
| Arrange view | one strip for each audio clip: the lowest to the highest sample for each pixel, the RMS as a brighter band inside, full scale in red |
| Vocal editor (utau) | two strips: the pitch lines under its notes, and its curve |

The strip of an audio clip is the strip of the whole clip. So, when you
scroll, paw moves pieces that it sent before and does not send them again.

A strip is **over** the text or **under** it:

- Over the text: its cells are blank (the score).
- Under the text: the cells of the view show as usual above the picture. The curve editor keeps its points, its cursor, the selection and the playhead as cells. The grid, the line and the area under the line are pixels, a sample for each pixel. Nothing of the curve shows two times.

## How paw sends a picture

paw makes the picture at the cell size of the terminal, and cuts it into
pieces at its barlines. An edit sends again only the bars that it changes.
A menu or a float over a part of the picture hides the pieces under
it.

What moves over the page (the cursor, the next note, the playhead) is a
picture of its own above the page. paw does this in the terminals that put
images over images well: kitty, Ghostty, and herdr (which answers as
libghostty). In
other terminals, WezTerm among them, paw draws it into the pieces that it
crosses.

A strip under the text is at a z of -2, and the parts that move at -1:

- In kitty, Ghostty, herdr and WezTerm, the text shows above the picture, and the picture above the colored backgrounds of the cells. The backgrounds show where the picture draws nothing.
- Konsole, and each terminal not known by its name, puts a colored background above such a picture, which hides it. There, paw paints the backgrounds of the cells (the lane, the notes, a selection) into the picture, and writes the cells on the background of the terminal. A background that is one run along one row (a cursor block, the note under the cursor) shows as cells. The picture keeps there what those cells had before. So a cursor that moves sends no pixels.

Over a picture, the pointer goes to the view in pixels where the terminal
reports them. Else it goes to the middle of the cell.

## Where there are no pictures

`paw attach` from a terminal that shows images shows them too. It tells
the instance what its terminal can do. The instance sends the drawing of
each strip (only when it changes), and `paw attach` makes the pixels.

Where the terminal shows no images, the view draws in cells. This occurs
in tmux (which does not send images through), in a terminal without the
protocol, and in `paw attach` from such a terminal. `:set graphics!`
(`paw.opt.graphics = false`) keeps cells everywhere. The same command again
gives the pictures back.
