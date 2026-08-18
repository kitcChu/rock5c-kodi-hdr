#!/usr/bin/env python3
import re, sys

p = "/home/radxa/.kodi/userdata/guisettings.xml"
s = open(p).read()

def set_setting(xml, sid, value):
    xml = re.sub(r"\s*<setting id=\"" + re.escape(sid) + r"\"[^>]*>.*?</setting>", "", xml)
    xml = re.sub(r"\s*<setting id=\"" + re.escape(sid) + r"\"[^>]*/>", "", xml)
    xml = xml.rstrip()
    assert xml.endswith("</settings>"), "missing closing tag"
    xml = xml[: -len("</settings>")] + '    <setting id="%s">%s</setting>\n</settings>\n' % (sid, value)
    return xml

for sid, val in [
    ("videoplayer.useprimedecoder", "true"),
    ("videoplayer.useprimedecoderforhw", "true"),
    ("videoplayer.usedisplayasclock", "true"),
    ("audiooutput.audiodevice", "ALSA:hw:CARD=Qutest,DEV=0"),
    ("audiooutput.passthrough", "false"),
    ("debug.showloginfo", "true"),
]:
    s = set_setting(s, sid, val)

open(p, "w").write(s)
print("guisettings.xml updated OK")
