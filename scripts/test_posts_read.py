#!/usr/bin/env python3 -I
"""Tests for the posts-and-comments readers (run: python3 -I scripts/test_posts_read.py).

Fixtures are synthetic: markup shapes cut from the real pages (class names, attribute layout), every name, id and text invented."""
import datetime, os, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import posts_read as pr  # noqa: E402

pr.ME = "Casey Keeper"   # the export owner the fixtures are written for (--me)
pr.ZONE_2011 = pr.parse_zone("UTC-04:00")   # the fixed offset the 2011 fixtures were written for (--zone)
import test_fb_saved_pages as tfs  # noqa: E402  (its saved-page fixtures)

WALL_2011 = """<html><head><title>Casey Keeper -  Wall </title></head><body><div id="content" class="tabwall">
<div class="feedentry"> <span class="profile">Casey Keeper</span> my status today
 <div class="timerow"> <span class="time">March 5, 2011 at 3:27 pm</span> </div>
 <div class="comments"><div class="comment like">2 people like this</div>
  <div class="comment"><span class="profile">Ann Bee</span> nice<br/><span class="time">March 5, 2011 at 3:38 pm</span></div>
  <div class="comment"><span class="profile">Casey Keeper</span> thanks<br/><span class="time">March 5, 2011 at 3:40 pm</span></div></div> </div>
<div class="feedentry"> <span class="profile">Cal Dee</span> <table class="walllink"><tr><td><a href="http://example.com/v">A video</a></td></tr></table>
 <div class="timerow"> <span class="time">July 4, 2010 at 10:00 am</span> </div> </div>
<div class="feedentry"> <span class="profile">Casey Keeper</span> Shopping album!
 <div class="timerow"> <span class="time">March 10, 2011 at 9:25 pm</span> </div>
 <div class="comments"><div class="comment"><span class="profile">Ann Bee</span> early comment<br/><span class="time">March 9, 2011 at 11:11 pm</span></div></div> </div>
</div></body></html>"""

ALBUM_2011 = """<html><body><div id="content" class="tabalbum"> <h2>Mobile Uploads</h2>
<div class="photo"> <a name="100000000000101"/> <a href="../photos/Mobile%20Uploads/x.jpg"><img src="../photos/Mobile%20Uploads/x.jpg"/></a> <br/>
 Invented caption! <br/> In this photo: <span class="profile">Casey Keeper</span> <br/>
 <a href="http://www.facebook.com/photo.php?pid=1"><span class="time">March 9, 2011 at 1:28 pm</span></a>
 <div class="comments"><div class="comment"><span class="profile">Ann Bee</span> Congrats!<br/><span class="time">March 9, 2011 at 1:29 pm</span></div></div> </div>
<div class="photo"> <a name="300"/> <a href="../photos/Mobile%20Uploads/y.jpg"><img src="../photos/Mobile%20Uploads/y.jpg"/></a> <br/>
 <a href="http://www.facebook.com/photo.php?pid=2"><span class="time">March 12, 2011 at 1:00 pm</span></a> </div>
</div></body></html>"""

VIDEOS_2011 = """<html><body><div id="content" class="tabvideos"> <a name="100000000000102"/> <div class="video"> <object></object>
<div class="vidinfo"> <a href="../videos/Flying.mp4">Flying</a> <br/> In this video: <span class="profile">Casey Keeper</span> <br/>
<span class="time">April 21, 2011 at 10:31 pm</span> </div>
<div class="comments"><div class="comment"><span class="profile">Zed Why</span> cool<br/><span class="time">April 21, 2011 at 10:53 pm</span></div></div></div>
</div></body></html>"""


def ms(y, mo, d, h, mi, off=-4):
    return int(datetime.datetime(y, mo, d, h, mi, tzinfo=datetime.timezone(datetime.timedelta(hours=off))).timestamp() * 1000)


class Reader2011(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        os.makedirs(os.path.join(self.d, "html"))
        for name, text in (("wall.html", WALL_2011), ("album-Mobile Uploads.html", ALBUM_2011), ("videos.html", VIDEOS_2011)):
            with open(os.path.join(self.d, "html", name), "w", encoding="utf-8") as f:
                f.write(text)
        self.head, self.recs = pr.read_fb2011(self.d, "test:origin")
        self.by = {r["rid"]: r for r in self.recs}

    def test_files_and_header(self):
        self.assertEqual([os.path.basename(f["path"]) for f in self.head["files"]], ["wall.html", "album-Mobile Uploads.html", "videos.html"])
        self.assertEqual(self.head["files"][0]["origin"], "test:origin/html/wall.html")
        self.assertEqual(len(self.head["files"][0]["sha256"]), 64)

    def test_wall_post_by_me_with_comments_at_fixed_minus_four(self):
        p = self.by["wall:0"]
        self.assertEqual((p["type"], p["kind"], p["by_me"], p["author"], p["body"], p["precision"]),
                         ("post", "wall-post", True, None, "my status today", "minute"))
        self.assertEqual(p["ts_ms"], ms(2011, 3, 5, 15, 27))
        c0, c1 = self.by["wall:0:c1"], self.by["wall:0:c2"]  # rids count the like line (index 0) too: the comment's place in the page
        self.assertEqual((c0["author"], c0["by_me"], c0["body"], c0["parent"], c0["ts_ms"]), ("Ann Bee", False, "nice", "wall:0", ms(2011, 3, 5, 15, 38)))
        self.assertTrue(c1["by_me"])
        # summer and winter both at UTC-04:00 (the calibrated rule), no daylight-saving switch
        self.assertEqual(self.by["wall:1"]["ts_ms"], ms(2010, 7, 4, 10, 0))

    def test_likes_are_left_out_and_counted(self):
        likes = [r for r in self.recs if r.get("what") == "like-line"]
        self.assertEqual(len(likes), 1)
        self.assertEqual((likes[0]["type"], likes[0]["reason"], likes[0]["parent"]), ("skip", "likes-left-out", "wall:0"))
        self.assertFalse(any(r["type"] == "post" and "like" in (r.get("body") or "") for r in self.recs))

    def test_post_printed_after_its_first_comment_is_left_out_with_its_comments(self):
        p, c = self.by["wall:2"], self.by["wall:2:c0"]
        self.assertEqual((p["type"], p["reason"]), ("skip", "time-not-own"))
        self.assertEqual((c["type"], c["reason"], c["parent"]), ("skip", "parent-left-out", "wall:2"))

    def test_friend_post_link(self):
        p = self.by["wall:1"]
        self.assertEqual((p["author"], p["by_me"], p["link"]), ("Cal Dee", False, "http://example.com/v"))

    def test_album_photos_and_videos(self):
        a = self.by["album1:100000000000101"]
        self.assertEqual((a["kind"], a["by_me"], a["body"], a["target_text"], a["external_id"], a["basis"]),
                         ("album-photo", True, "Invented caption!", "Mobile Uploads", "100000000000101", "uploaded"))
        self.assertEqual(self.by["album1:100000000000101:c0"]["body"], "Congrats!")
        self.assertIsNone(self.by["album1:300"]["body"])
        v = self.by["video:100000000000102"]
        self.assertEqual((v["kind"], v["body"], v["ts_ms"]), ("video", "Flying", ms(2011, 4, 21, 22, 31)))
        self.assertEqual(self.by["video:100000000000102:c0"]["author"], "Zed Why")

    def test_dkeys_unique_and_stable(self):
        keys = [r["dkey"] for r in self.recs if r.get("dkey")]
        self.assertEqual(len(keys), len(set(keys)))
        _, again = pr.read_fb2011(self.d, "test:origin")
        self.assertEqual(keys, [r["dkey"] for r in again if r.get("dkey")])

    def test_repeated_dkey_gets_an_ordinal(self):
        out = pr.Out()
        out.add({"dkey": "k"}); out.add({"dkey": "k"})
        self.assertEqual([r["dkey"] for r in out.recs], ["k", "k#2"])


REPEATS_WALL = """<html><body><div id="content" class="tabwall">
<div class="feedentry"> <span class="profile">Casey Keeper</span> Invented caption! <a href="album-Mobile%20Uploads.html#100000000000101">x</a>
 <div class="timerow"> <span class="time">March 9, 2011 at 1:28 pm</span> </div>
 <div class="comments"><div class="comment like">3 people like this</div>
  <div class="comment"><span class="profile">Ann Bee</span> Congrats!<br/><span class="time">March 9, 2011 at 1:29 pm</span></div>
  <div class="comment"><span class="profile">Bo Sea</span> only on the wall<br/><span class="time">March 9, 2011 at 2:00 pm</span></div></div> </div>
<div class="feedentry"> <span class="profile">Casey Keeper</span> Flying
 <div class="timerow"> <span class="time">April 21, 2011 at 10:31 pm</span> </div> </div>
<div class="feedentry"> <span class="profile">Kay Tee</span> happy birthday!
 <div class="timerow"> <span class="time">August 30, 2010 at 4:25 pm</span> </div>
 <div class="comments"><div class="comment"><span class="profile">Casey Keeper</span> thanks<br/><span class="time">August 30, 2010 at 4:30 pm</span></div></div> </div>
<div class="feedentry"> <span class="profile">Kay Tee</span> happy birthday!
 <div class="timerow"> <span class="time">August 30, 2010 at 4:25 pm</span> </div>
 <div class="comments"><div class="comment"><span class="profile">Casey Keeper</span> thanks<br/><span class="time">August 30, 2010 at 4:30 pm</span></div></div> </div>
<div class="feedentry"> <span class="profile">Kay Tee</span> happy birthday!
 <div class="timerow"> <span class="time">August 30, 2010 at 4:25 pm</span> </div> <a href="http://example.com/other">other</a></div>
</div></body></html>"""


class Repeats2011(unittest.TestCase):
    """The 2011 export prints a photo's or video's story on the wall too, and some wall stories twice: one record each."""

    def setUp(self):
        self.d = tempfile.mkdtemp()
        os.makedirs(os.path.join(self.d, "html"))
        for name, text in (("wall.html", REPEATS_WALL), ("album-Mobile Uploads.html", ALBUM_2011), ("videos.html", VIDEOS_2011)):
            with open(os.path.join(self.d, "html", name), "w", encoding="utf-8") as f:
                f.write(text)
        _, self.recs = pr.read_fb2011(self.d, None)
        self.by = {r["rid"]: r for r in self.recs}

    def test_wall_story_of_an_album_photo_is_the_photo(self):
        w = self.by["wall:0"]
        self.assertEqual((w["type"], w["reason"], w["same_as"]), ("skip", "repeat-in-export", "album1:100000000000101"))
        self.assertEqual((self.by["wall:0:c1"]["type"], self.by["wall:0:c1"]["reason"]), ("skip", "repeat-in-export"))  # Congrats!, already on the photo
        moved = self.by["wall:0:c2"]                                                                                       # only on the wall: kept, on the photo
        self.assertEqual((moved["type"], moved["parent"], moved["body"]), ("comment", "album1:100000000000101", "only on the wall"))
        photo_comments = [r for r in self.recs if r["type"] == "comment" and r["parent"] == "album1:100000000000101"]
        self.assertEqual(sorted(c["body"] for c in photo_comments), ["Congrats!", "only on the wall"])

    def test_wall_story_with_a_video_title_in_its_minute_is_the_video(self):
        self.assertEqual((self.by["wall:1"]["reason"], self.by["wall:1"]["same_as"]), ("repeat-in-export", "video:100000000000102"))

    def test_a_wall_story_printed_twice_is_one_post(self):
        posts = [r for r in self.recs if r["type"] == "post" and r["kind"] == "wall-post"]
        self.assertEqual([p["rid"] for p in posts], ["wall:2", "wall:4"])  # wall:4 has another link: a different post
        self.assertEqual((self.by["wall:3"]["reason"], self.by["wall:3"]["same_as"]), ("repeat-in-export", "wall:2"))
        self.assertEqual(self.by["wall:3:c0"]["reason"], "repeat-in-export")

    def test_an_album_story_printed_at_every_update_is_one_post_at_its_first_printing(self):
        # three printings of one album story, linking to two photos, each with the album's comment thread
        album = ALBUM_2011
        wall = """<html><body><div id="content" class="tabwall">""" + "".join(
            f"""<div class="feedentry"> <span class="profile">Casey Keeper</span> Shopping! <a href="album-Mobile%20Uploads.html#{pid}">x</a>
            <div class="timerow"> <span class="time">{when}</span> </div>
            <div class="comments"><div class="comment"><span class="profile">Dee Eff</span> love these<br/><span class="time">March 12, 2011 at 3:00 pm</span></div></div></div>"""
            for pid, when in (("300", "March 13, 2011 at 9:25 pm"), ("100000000000101", "March 9, 2011 at 1:30 pm"), ("300", "March 12, 2011 at 1:05 pm"))) + "</div></body></html>"
        d = tempfile.mkdtemp(); os.makedirs(os.path.join(d, "html"))
        for name, text in (("wall.html", wall), ("album-Mobile Uploads.html", album)):
            with open(os.path.join(d, "html", name), "w", encoding="utf-8") as f:
                f.write(text)
        _, recs = pr.read_fb2011(d, None)
        by = {r["rid"]: r for r in recs}
        posts = [r for r in recs if r["type"] == "post" and r["kind"] == "wall-post"]
        self.assertEqual([p["rid"] for p in posts], ["wall:1"])                     # the earliest printing, its own time
        self.assertEqual(posts[0]["target_text"], "Mobile Uploads")
        self.assertEqual([r["rid"] for r in recs if r["type"] == "comment" and r["parent"] == "wall:1"], ["wall:1:c0"])
        self.assertEqual({by["wall:0"]["reason"], by["wall:2"]["reason"]}, {"repeat-in-export"})
        self.assertEqual({by["wall:0:c0"]["reason"], by["wall:2:c0"]["reason"]}, {"repeat-in-export"})

    def test_stories_of_two_photos_with_the_same_text_and_no_shared_comments_stay_the_photos(self):
        wall = """<html><body><div id="content" class="tabwall">""" + "".join(
            f"""<div class="feedentry"> <span class="profile">Casey Keeper</span> {body} <a href="album-Mobile%20Uploads.html#{pid}">x</a>
            <div class="timerow"> <span class="time">{when}</span> </div></div>"""
            for pid, when, body in (("300", "March 12, 2011 at 1:00 pm", "Mobile Uploads"), ("100000000000101", "March 9, 2011 at 1:28 pm", "Mobile Uploads"),
                                    ("300", "March 12, 2011 at 2:00 pm", ""), ("100000000000101", "March 9, 2011 at 3:00 pm", ""))) + "</div></body></html>"
        d = tempfile.mkdtemp(); os.makedirs(os.path.join(d, "html"))
        for name, text in (("wall.html", wall), ("album-Mobile Uploads.html", ALBUM_2011)):
            with open(os.path.join(d, "html", name), "w", encoding="utf-8") as f:
                f.write(text)
        _, recs = pr.read_fb2011(d, None)
        self.assertEqual([r for r in recs if r["type"] == "post" and r["kind"] == "wall-post"], [])
        self.assertEqual(sorted(r["same_as"] for r in recs if r.get("reason") == "repeat-in-export" and r["what"] == "wall-post"),
                         ["album1:100000000000101", "album1:100000000000101", "album1:300", "album1:300"])
        self.assertEqual(len([r for r in self.recs if r["type"] == "comment" and r["parent"] == "wall:2"]), 1)

    def test_every_written_record_once(self):
        keys = [r["dkey"] for r in self.recs if r["type"] in ("post", "comment")]
        self.assertEqual(len(keys), len(set(keys)))
        self.assertFalse(any("#" in k for k in keys))


class ReaderSavedPages(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()

    def page(self, name, text):
        p = os.path.join(self.d, name)
        with open(p, "w", encoding="utf-8") as f:
            f.write(text)
        return p

    def test_group_post_and_comments_exact_seconds(self):
        p = self.page("g.html", tfs.GROUP_POST_2013)
        head, recs = pr.read_saved_pages([p], {p: "host:/x/g.html"})
        self.assertEqual(head["files"][0]["origin"], "host:/x/g.html")
        post = [r for r in recs if r["type"] == "post"][0]
        self.assertEqual((post["kind"], post["author"], post["ts_ms"], post["precision"], post["target_text"], post["dkey"]),
                         ("group-post", "Poster One", 1384810146000, "second", "Some Group", "fbpage|post|222"))
        cs = [r for r in recs if r["type"] == "comment"]
        self.assertEqual([(c["author"], c["ts_ms"], c["parent"]) for c in cs],
                         [("Ann Bee", 1384813027000, post["rid"]), ("Me Person", 1384813100000, post["rid"])])

    def test_saved_post_printed_after_its_comment_is_left_out(self):
        text = tfs.GROUP_POST_2013.replace("&quot;content_timestamp&quot;:&quot;1384810146&quot;", "&quot;content_timestamp&quot;:&quot;1384813050&quot;")
        p = self.page("g2.html", text)
        _, recs = pr.read_saved_pages([p], {})
        self.assertEqual([r["reason"] for r in recs if r["type"] == "skip"], ["time-not-own", "parent-left-out", "parent-left-out"])

    def test_unavailable_page_has_no_records(self):
        p = self.page("u.html", "<html><body>Sorry, this content isn't available right now</body></html>")
        head, recs = pr.read_saved_pages([p], {})
        self.assertEqual(recs, [])
        self.assertEqual(len(head["files"]), 1)



# ---- matching edge cases, one test per case ----

def _export(files):
    d = tempfile.mkdtemp()
    os.makedirs(os.path.join(d, "html"))
    for name, text in files.items():
        with open(os.path.join(d, "html", name), "w", encoding="utf-8") as f:
            f.write(text)
    return d


class NearMatches(unittest.TestCase):
    def test_two_identical_comments_under_one_photo_are_kept_and_noted(self):
        album = ALBUM_2011.replace('<div class="comments"><div class="comment"><span class="profile">Ann Bee</span> Congrats!<br/><span class="time">March 9, 2011 at 1:29 pm</span></div></div>',
                                   '<div class="comments">' + '<div class="comment"><span class="profile">Ann Bee</span> Congrats!<br/><span class="time">March 9, 2011 at 1:29 pm</span></div>' * 2 + '</div>')
        _, recs = pr.read_fb2011(_export({"wall.html": "<html><body></body></html>", "album-Mobile Uploads.html": album}), None)
        recs = pr.annotate_near_matches(recs)
        cs = [r for r in recs if r["type"] == "comment"]
        self.assertEqual(len(cs), 2)
        self.assertTrue(all("printed twice under the same post" in c["near_match"] for c in cs))
        self.assertEqual(len({c["dkey"] for c in cs}), 2)


class ReaderEdgeCases(unittest.TestCase):
    def test_the_same_comment_text_on_two_different_posts_is_two_comments(self):
        wall = """<html><body><div class="feedentry"><span class="profile">Casey Keeper</span>first post<div class="timerow"><span class="time">March 5, 2011 at 3:27 pm</span></div>
        <div class="comments"><div class="comment"><span class="profile">Ann Bee</span>nice<br/><span class="time">March 5, 2011 at 3:38 pm</span></div></div></div>
        <div class="feedentry"><span class="profile">Casey Keeper</span>second post<div class="timerow"><span class="time">March 5, 2011 at 3:27 pm</span></div>
        <div class="comments"><div class="comment"><span class="profile">Ann Bee</span>nice<br/><span class="time">March 5, 2011 at 3:38 pm</span></div></div></div></body></html>"""
        _, recs = pr.read_fb2011(_export({"wall.html": wall}), None)
        by = {r["rid"]: r for r in recs}
        self.assertEqual((by["wall:0:c0"]["type"], by["wall:0:c0"]["parent"]), ("comment", "wall:0"))
        self.assertEqual((by["wall:1:c0"]["type"], by["wall:1:c0"]["parent"]), ("comment", "wall:1"))

    def test_a_photo_link_inside_a_comment_does_not_make_the_post_that_photo(self):
        wall = """<html><body><div class="feedentry"><span class="profile">Cal Dee</span>Unrelated April status<div class="timerow"><span class="time">April 5, 2011 at 3:27 pm</span></div>
        <div class="comments"><div class="comment"><span class="profile">Ann Bee</span>see <a href="album-Mobile%20Uploads.html#100000000000101">this photo</a><br/><span class="time">April 5, 2011 at 3:38 pm</span></div></div></div></body></html>"""
        _, recs = pr.read_fb2011(_export({"wall.html": wall, "album-Mobile Uploads.html": ALBUM_2011}), None)
        by = {r["rid"]: r for r in recs}
        self.assertEqual((by["wall:0"]["type"], by["wall:0"]["author"], by["wall:0"]["link"]), ("post", "Cal Dee", None))
        self.assertEqual(by["wall:0:c0"]["parent"], "wall:0")

    def test_the_same_facebook_id_in_two_saved_pages_is_one_record(self):
        d = tempfile.mkdtemp()
        paths = []
        for n in ("a.html", "b.html"):
            p = os.path.join(d, n)
            with open(p, "w", encoding="utf-8") as f:
                f.write(tfs.GROUP_POST_2013)
            paths.append(p)
        _, recs = pr.read_saved_pages(paths, {})
        written = [r for r in recs if r["type"] in ("post", "comment")]
        self.assertEqual(sorted(r["dkey"] for r in written), ["fbpage|comment|222_901", "fbpage|comment|222_902", "fbpage|post|222"])
        rep = [r for r in recs if r["type"] == "skip"]
        self.assertEqual([r["reason"] for r in rep], ["repeat-in-export"] * 3)
        self.assertTrue(all(r.get("same_as") for r in rep))

    def test_the_audit_compares_a_photo_with_its_own_printed_time(self):
        import posts_invariants as inv
        inv.TZ_2011 = pr.ZONE_2011
        album = """<html><body><div id="content" class="tabalbum"><h2>A</h2>
        <div class="photo"><a name="111"/><a href="x"><img src="a.jpg"/></a><br/><a href="p"><span class="time">March 9, 2011 at 1:28 pm</span></a></div>
        <div class="photo"><a name="222"/><a href="y"><img src="b.jpg"/></a><br/><a href="p"><span class="time">March 12, 2011 at 9:00 am</span></a></div>
        </div></body></html>"""
        d = _export({"album-A.html": album})
        times = inv.media_times_2011([os.path.join(d, "html", "album-A.html")])
        self.assertEqual(times, {"111": ms(2011, 3, 9, 13, 28), "222": ms(2011, 3, 12, 9, 0)})
        self.assertTrue(inv.media_time_ok("111", ms(2011, 3, 9, 13, 28), times))
        self.assertFalse(inv.media_time_ok("111", ms(2011, 3, 12, 9, 0), times))   # another photo's time is not its own


class MatchingKeys(unittest.TestCase):
    """Reader edge cases."""

    def test_texts_that_differ_only_in_punctuation_have_their_own_keys_in_any_order(self):
        def wall(order):
            e = {"Go!": '<div class="feedentry"><span class="profile">Casey Keeper</span>Go!<div class="timerow"><span class="time">March 5, 2011 at 3:27 pm</span></div>'
                        '<div class="comments"><div class="comment"><span class="profile">Ann Bee</span>new reply<br/><span class="time">March 5, 2011 at 3:38 pm</span></div></div></div>',
                 "Go?": '<div class="feedentry"><span class="profile">Casey Keeper</span>Go?<div class="timerow"><span class="time">March 5, 2011 at 3:27 pm</span></div></div>'}
            return "<html><body>" + "".join(e[k] for k in order) + "</body></html>"
        keys = []
        for order in (("Go!", "Go?"), ("Go?", "Go!")):
            _, recs = pr.read_fb2011(_export({"wall.html": wall(order)}), None)
            keys.append({r["body"]: r["dkey"] for r in recs if r["type"] in ("post", "comment")})
        self.assertEqual(keys[0], keys[1])
        self.assertFalse(any("#" in k for k in keys[0].values()))
        self.assertNotEqual(keys[0]["Go!"], keys[0]["Go?"])

    def test_comments_without_a_facebook_id_are_never_merged_by_their_synthesized_key(self):
        d = tempfile.mkdtemp()
        paths = []
        for n, body in (("a.html", "Great!"), ("b.html", "Great?")):
            text = (tfs.GROUP_POST_2013.replace('data-reactid=".r[1].{comment222_901}"', "").replace("?comment_id=901&amp;offset=0", "")
                    .replace("first comment", body))
            p = os.path.join(d, n)
            with open(p, "w", encoding="utf-8") as f:
                f.write(text)
            paths.append(p)
        _, recs = pr.read_saved_pages(paths, {})
        bodies = sorted(r["body"] for r in recs if r["type"] == "comment" and r["author"] == "Ann Bee")
        self.assertEqual(bodies, ["Great!", "Great?"])
        self.assertFalse(any(r.get("note") == "the same Facebook id is in an earlier page" and r["what"] == "comment" and "|" in r["rid"].split(":comment:")[1]
                             for r in recs if r["type"] == "skip"))


class ZoneOption(unittest.TestCase):
    def test_fb2011_needs_a_zone_and_parses_names_and_offsets(self):
        self.assertEqual(pr.main(["posts_read.py", "fb2011", "--me", "Casey Keeper", tempfile.mkdtemp()]), 2)
        self.assertEqual(pr.parse_zone("UTC-04:00").utcoffset(None), datetime.timedelta(hours=-4))
        self.assertEqual(pr.parse_zone("UTC+5:30").utcoffset(None), datetime.timedelta(hours=5, minutes=30))
        self.assertEqual(str(pr.parse_zone("America/Chicago")), "America/Chicago")
        self.assertEqual(pr.zone_label(pr.parse_zone("UTC-04:00")), "fixed UTC-04:00")


if __name__ == "__main__":
    unittest.main()
