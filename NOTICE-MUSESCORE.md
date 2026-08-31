# MuseScore and Qt source notice

MuseReader's Android and iOS product builds link the MuseScore 3.6.2
`libmscore` engine supplied with the project materials. The mobile application
requires this native backend; it is not an optional compatibility component.
MuseScore 3.6.2 is distributed under the GNU General Public License, version 2.
The original source and its license files are kept in the supplied checkout:

`/Volumes/Files/Github/MuseScore-3.6.2/`

The product packages also link Qt 5.15.2 Core, Gui, Widgets, Xml and Svg, and
compile Qt's minimal platform plugin. Qt's open-source distribution includes
GPL/LGPL license choices and component-specific notices. MuseScore's qzip and
FreeType dependencies retain their own upstream notices in the supplied source
tree.

Before distributing an APK or IPA, include the applicable license texts,
copyright notices, corresponding source (including the mobile adapter and any
Qt modifications), and any written source offer or relinking materials required
by the selected licenses. The unsigned/debug-signed artifacts produced by this
repository are engineering deliverables, not evidence of legal or app-store
compliance.
