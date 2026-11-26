#!/usr/bin/env python3 -I
"""Tests for the saved-Facebook-page reader (run: python3 -I scripts/test_fb_saved_pages.py).

Fixtures are synthetic: the markup shapes are cut from the real 2011, 2013 and 2018 pages (class names, attribute
layout, id forms), every name, id and text is invented."""
import os, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fb_saved_pages as fsp  # noqa: E402

ME = "100000000000001"

MESSAGES_2013 = """<!DOCTYPE html>
<!-- saved from url=(0040)https://www.facebook.com/messages/pat.q9 -->
<html><head><title id="pageTitle">Pat Quill - Messages</title>
<script>require("ServerJS").handle({"USER_ID":"%(me)s"});Env={serverTime:1386100000000};</script></head><body>
<ul class="uiList _2ne _4kg" id="webMessengerRecentMessages">
<li class="_2n3"><abbr data-utime="0" class="timestamp">November 3</abbr></li>
<li class="webMessengerMessageGroup clearfix" id="wm:mid.1386100100000:aa01"><div class="clearfix">
 <div class="_2w7 _8o _8t lfloat"><a href="https://www.facebook.com/me.person"><img class="img _50dv" src="./x_files/me_q.jpg" alt="Me Person" width="32" height="32"></a></div>
 <div class="clearfix _42ef"><div class="rfloat"><a class="_b9"><abbr title="December 3" data-utime="1386100100.000" class="_35 timestamp">10:08pm</abbr></a></div>
 <div><strong class="_36"><a href="https://www.facebook.com/me.person" data-hovercard="/ajax/hovercard/hovercard.php?id=%(me)s&amp;extragetparams=%%7B%%7D">Me Person</a></strong>
 <div class="_37"><div class="_53" id="mid.1386100100000:aa01"><div class="_3hi clearfix">
   <div class="_38 direction_ltr"><span><p>first line</p><p>second line</p></span></div>
   <div class="_38 direction_ltr"><span><p>a second message in the block <img class="emoticon emoticon_smile" alt=":)" src="x.png"></p></span></div>
 </div></div></div></div></div></div></li>
<li class="webMessengerMessageGroup clearfix" id="wm:mid.1386100200500:bb02"><div class="clearfix">
 <div><strong class="_36"><a href="https://www.facebook.com/pat.q9" data-hovercard="/ajax/hovercard/hovercard.php?id=555">Pat Quill</a></strong>
 <div class="_37"><div class="_53" id="mid.1386100200500:bb02"><div class="_3hi clearfix">
   <div class="_38 direction_ltr"><span><p>reply</p></span></div>
   <div class="_38 direction_ltr"><span><p>later in the same block</p></span></div>
   <div class="_59go"><a href="#"><img src="./x_files/photo_n.jpg" width="200" height="150"></a></div>
 </div></div></div></div></div></li>
</ul></body></html>""" % {"me": ME}

GROUP_POST_2013 = """<html><!-- saved from url=(0060)https://www.facebook.com/groups/111/222/ --><head><title id="pageTitle">(1) Some Group</title>
<script>Env={serverTime:1384833667000};</script></head><body>
<div class="story"><h5 class="uiStreamMessage"><a href="https://www.facebook.com/poster.one" data-hovercard="/ajax/hovercard/user.php?id=777">Poster One</a> posted</h5>
<h5 class="uiStreamMessage userContentWrapper"><span class="messageBody"><span class="userContent">A post <span class="text_exposed_hide">...</span><span class="text_exposed_show">with more</span></span></span></h5>
<form rel="async" class="live_222_316 commentable_item autoexpand_mode" method="post">
<input type="hidden" name="feedback_params" value="{&quot;actor&quot;:&quot;777&quot;,&quot;target_fbid&quot;:&quot;222&quot;,&quot;assoc_obj_id&quot;:&quot;111&quot;,&quot;content_timestamp&quot;:&quot;1384810146&quot;}">
<ul class="UFIList">
<li class="UFIRow UFIComment display UFIFirstComment" data-reactid=".r[1].{comment222_901}"><div class="clearfix"><div class="lfloat"><a class="img UFIImageBlockImage"><img src="./g_files/a_q.jpg" class="img UFIActorImage _54ru"></a></div>
 <div class="clearfix UFIImageBlockContent _42ef"><div class="rfloat"><a class="uiCloseButton UFICommentCloseButton"><img class="img uiCloseButtonHighContrast" src="./g_files/close.png"></a></div>
 <div><div class="UFICommentContent"><a class="UFICommentActorName" href="https://www.facebook.com/a.b" data-hovercard="/ajax/hovercard/hovercard.php?id=888&amp;extragetparams=%%7B%%7D">Ann Bee</a><span> </span><span><span>first comment</span></span></div>
 <div class="fsm fwn fcg UFICommentActions"><a class="uiLinkSubtle" href="https://www.facebook.com/groups/111/222/?comment_id=901&amp;offset=0"><abbr class="livetimestamp" title="Monday, November 18, 2013 at 5:17pm" data-utime="1384813027">Yesterday at 5:17pm</abbr></a></div></div></div></div></li>
<li class="UFIRow UFIComment display" data-reactid=".r[1].{comment222_902}"><div class="UFICommentContent"><a class="UFICommentActorName" href="https://www.facebook.com/me.person" data-hovercard="/ajax/hovercard/hovercard.php?id=%(me)s">Me Person</a><span><span>second <br>comment</span></span></div>
 <a class="uiLinkSubtle" href="?comment_id=902"><abbr class="livetimestamp" title="t" data-utime="1384813100">x</abbr></a></li>
</ul></form></div></body></html>""" % {"me": ME}

TIMELINE_2018 = """<html><head><title id="pageTitle">Someone</title><script>{"USER_ID":"%(me)s"} serverTime:1533069103000</script></head><body>
<code class="hidden_elem"><!-- <div class="_5pcr userContentWrapper"><h5><span class="fwb"><a href="https://www.facebook.com/x.y?fref=nf" data-hovercard="/ajax/hovercard/user.php?id=42">Xa Yo</a></span></h5>
<a class="_5pcq" href="/x.y/posts/9001"><abbr title="07/20/2018 3:41pm" data-utime="1532126476" class="_5ptz"><span class="timestampContent">July 20</span></abbr></a>
<div class="_5pbx userContent"><p>hello there</p></div></div> --></code></body></html>""" % {"me": ME}

DYI_MESSAGES = """<html><head><title>Me Person -  Messages </title></head><body><div id="content" class="tabmessages">
<div class="thread"><div class="message"><span class="profile">Kim Lo</span>
<span class="time">May 10, 2011 at 9:42 pm</span><div class="msgbody"><div class="subject">Hi</div>opening line<BR><BR>more</div></div>
<div class="message reply"><span class="profile">Me Person</span><span class="time">May 10, 2011 at 9:45 pm</span><div class="msgbody">a reply that is long enough</div></div>
</div>
<div class="thread"><div class="message"><span class="profile">Me Person</span> and <span class="profile">Jo Ra</span>
<span class="time">January 2, 2010 at 8:00 am</span><div class="msgbody">winter message long enough</div></div></div>
</div></body></html>"""

DYI_WALL = """<html><head><title>Me Person -  Wall </title></head><body><div id="content" class="tabwall">
<div class="feedentry"><span class="profile">Me Person</span> wrote something.<div class="timerow"> <span class="time">November 10, 2009 at 8:14 pm</span> </div>
<div class="comments"><div class="comment like">Kim Lo likes this.</div>
<div class="comment"><span class="profile">Kim Lo</span>nice<br/><span class="time">November 10, 2009 at 8:20 pm</span></div></div></div>
</div></body></html>"""


def write(d, name, text, mtime=None):
    p = os.path.join(d, name)
    with open(p, "w", encoding="utf-8") as f:
        f.write(text)
    if mtime:
        os.utime(p, (mtime, mtime))
    return p


class Reader(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()

    def test_messages_thread_times_and_blocks(self):
        p = write(self.d, "m.html", MESSAGES_2013, mtime=1386100900)  # saved 15 min after serverTime: an original copy
        page = fsp.read_page(p, os.path.getmtime(p))
        self.assertEqual(page["meta"]["kind"], "messages-thread")
        self.assertEqual(page["meta"]["viewer_fbid"], ME)
        self.assertEqual(page["meta"]["save_ms"], 1386100900000)
        m = page["records"]
        self.assertEqual([r["precision"] for r in m], ["exact-ms", "block", "exact-ms", "block"])
        self.assertEqual(m[0]["text"], "first line\nsecond line")
        self.assertEqual(m[1]["text"], "a second message in the block :)")
        self.assertEqual(m[1]["ts_ms"], 1386100100000)
        self.assertEqual(m[1]["block_end_ms"], 1386100200500)  # the next block's start
        self.assertEqual(m[3]["block_end_ms"], 1386100900000)  # the last block ends at the save time
        self.assertEqual(m[0]["author"]["fbid"], ME)
        self.assertEqual(m[2]["author"]["name"], "Pat Quill")
        self.assertEqual(m[0]["thread"]["other"], "Pat Quill")
        self.assertEqual(m[3]["attachments"], ["./x_files/photo_n.jpg"])
        self.assertEqual(m[0]["attachments"], [])  # the 32 px profile picture is not an attachment

    def test_last_block_end_unknown_when_mtime_is_a_copy_date(self):
        p = write(self.d, "m.html", MESSAGES_2013, mtime=1775000000)  # a 2026 copy date: not the save time
        page = fsp.read_page(p, os.path.getmtime(p))
        self.assertEqual(page["meta"]["save_basis"], "page serverTime")
        self.assertIsNone(page["records"][3]["block_end_ms"])  # serverTime is before the block: end unknown

    def test_group_post_and_comments(self):
        page = fsp.read_page(write(self.d, "g.html", GROUP_POST_2013))
        self.assertEqual(page["meta"]["kind"], "group-post")
        post, c1, c2 = page["records"]
        self.assertEqual((post["kind"], post["id"], post["group_fbid"], post["ts_ms"]), ("post", "222", "111", 1384810146000))
        self.assertEqual(post["author"]["name"], "Poster One")
        self.assertEqual(post["text"], "A post with more")  # the "..." stub is dropped
        self.assertEqual((c1["id"], c1["parent"], c1["author"]["fbid"], c1["text"], c1["ts_ms"]),
                         ("222_901", "222", "888", "first comment", 1384813027000))
        self.assertEqual(c1["attachments"], [])  # actor picture and close button are not attachments
        self.assertEqual(c2["text"], "second\ncomment")
        self.assertEqual(c2["precision"], "exact-s")

    def test_deferred_code_block_timeline(self):
        page = fsp.read_page(write(self.d, "t.html", TIMELINE_2018))
        self.assertEqual(page["meta"]["kind"], "timeline")
        (post,) = page["records"]
        self.assertEqual((post["id"], post["author"]["name"], post["text"], post["ts_ms"]), ("9001", "Xa Yo", "hello there", 1532126476000))

    def test_unavailable_page(self):
        page = fsp.read_page(write(self.d, "u.html", "<html><title>Facebook</title><body>Sorry, this content isn&#039;t available right now</body></html>"))
        self.assertEqual(page["meta"]["kind"], "unavailable")
        self.assertEqual(page["records"], [])

    def test_dyi_2011(self):
        msgs = fsp.read_page(write(self.d, "messages.html", DYI_MESSAGES))
        self.assertEqual(msgs["meta"]["kind"], "dyi-2011-messages")
        r = msgs["records"]
        self.assertEqual(len(r), 3)
        self.assertEqual((r[0]["author"]["name"], r[0]["subject"], r[0]["text"], r[0]["local_minute"]), ("Kim Lo", "Hi", "opening line\nmore", "2011-05-10T21:42"))
        self.assertTrue(r[1]["is_reply"])
        self.assertEqual(r[2]["to"], ["Jo Ra"])
        wall = fsp.read_page(write(self.d, "wall.html", DYI_WALL))
        kinds = [x["kind"] for x in wall["records"]]
        self.assertEqual(kinds, ["post", "like-line", "comment"])
        self.assertEqual(wall["records"][0]["text"], "wrote something.")
        self.assertEqual((wall["records"][2]["text"], wall["records"][2]["local_minute"]), ("nice", "2009-11-10T20:20"))

    def test_norm_text(self):
        self.assertEqual(fsp.norm_text("Héllo,  World! :)"), fsp.norm_text("héllo world"))


if __name__ == "__main__":
    unittest.main(verbosity=1)
