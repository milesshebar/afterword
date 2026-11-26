import Testing
import Foundation
@testable import ArchiveCore

/// Instagram's Burmese system lines and Apple tapbacks stored as text. Synthetic names and handles only.
@Suite struct SystemLinesTests {
    @Test func likesAndReactionsBecomeSystemNotes() {
        #expect(InstagramSystemLines.translate("မက်ဆေ့တစ်စောင်ကို နှစ်သက်ခဲ့ပါတယ်", actor: "kate")?.note == "kate liked a message")
        #expect(InstagramSystemLines.translate("သင့်မက်ဆေ့  ကို ❤️ ပေးထားပါတယ်", actor: "kate")?.note == "kate reacted ❤️ to your message")
        // username prefix, with and without a space before က, wins over the sender
        #expect(InstagramSystemLines.translate("sam_x က သင့်မက်ဆေ့  ကို 😂 ပေးထားပါတယ်။", actor: "other")?.note == "sam_x reacted 😂 to your message")
        #expect(InstagramSystemLines.translate("sam_x က မက်ဆေ့တစ်စောင်ကို နှစ်သက်ခဲ့ပါတယ်", actor: nil)?.note == "sam_x liked a message")
    }

    @Test func callsKeepKindCall() {
        let started = InstagramSystemLines.translate("ဗီဒီယိုစကားဝိုင်းတစ်ခုကို သင်စတင်ခဲ့ပါတယ်", actor: nil)
        #expect(started?.kind == "call" && started?.note == "You started a video call")
        #expect(InstagramSystemLines.translate("ဗီဒီယိုစကားဝိုင်း တစ်ခုကို သင်လွတ်သွားခဲ့ပါတယ်", actor: nil)?.note == "You missed a video call")
        #expect(InstagramSystemLines.translate("ဗီဒီယိုစကားဝိုင်း ပြီးဆုံးသွားပါပြီ", actor: nil)?.note == "Video call ended")
        #expect(InstagramSystemLines.translate("အသံခေါ်ဆိုမှုတစ်ခုကို သင်စတင်ခဲ့ပါတယ်", actor: nil)?.note == "You started an audio call")
        #expect(InstagramSystemLines.translate("အသံခေါ်ဆိုမှု ပြီးဆုံးသွားပါပြီ", actor: nil)?.note == "Audio call ended")
        #expect(InstagramSystemLines.translate("အသံခေါ်ဆိုမှုတစ်ခုကို သင်မကိုင်ဖြစ်လိုက်ပါဘူး", actor: nil)?.note == "You missed an audio call")
        #expect(InstagramSystemLines.translate("ollie က အသံခေါ်ဆိုမှုတစ်ခု စတင်ခဲ့ပါတယ်", actor: nil)?.note == "ollie started an audio call")
    }

    @Test func connectionNotice() {
        #expect(InstagramSystemLines.translate("အခုဆိုရင် သင့်အနေနဲ့ အပြန်အလှန် မက်ဆေ့ပို့တာနဲ့ ဖုန်းခေါ်ဆိုတာကို လုပ်ဆောင်နိုင်ပြီ", actor: nil)?.fallback == false)
    }

    @Test func groupEvents() {
        #expect(InstagramSystemLines.translate("အဆက်အသွယ်တစ်ဦးက အဖွဲ့ကို ဖန်တီးခဲ့ပါတယ်။", actor: nil)?.note == "A contact created the group")
        #expect(InstagramSystemLines.translate("Max Laz ကို အဖွဲ့ထဲ သင်ထည့်သွင်းခဲ့ပါတယ်။", actor: nil)?.note == "You added Max Laz to the group")
        #expect(InstagramSystemLines.translate("အဆက်အသွယ်တစ်ဦးက Carl Example နဲ့ အခြား ၂၃ ဦးကို အဖွဲ့ထဲ ထည့်သွင်းခဲ့ပါတယ်။", actor: nil)?.note == "A contact added Carl Example and 23 others to the group")
        #expect(InstagramSystemLines.translate("sam က အဖွဲ့အမည်ကို tech support လို့ ပေးခဲ့ပါတယ်။", actor: nil)?.note == "sam named the group tech support")
        #expect(InstagramSystemLines.translate("sam က စကားဝိုင်း အရောင်ကို Winter Wonderland အဖြစ် ပြောင်းခဲ့ပါတယ်", actor: nil)?.note == "sam changed the theme to Winter Wonderland")
        #expect(InstagramSystemLines.translate("အဆက်အသွယ်တစ်ဦး ဒီအဖွဲ့က ထွက်သွားပါပြီ။", actor: nil)?.note == "A contact left the group")
    }

    @Test func unknownMyanmarLineFallsBackAndPlainTextIsLeftAlone() {
        let r = InstagramSystemLines.translate("သင်ဟာ ဒီစကားဝိုင်းကို အသစ်တစ်ခုအဖြစ် မှတ်ထားပါတယ်", actor: nil)
        #expect(r?.fallback == true && r?.note == "(Instagram system line)")
        #expect(InstagramSystemLines.translate("see you at 8", actor: nil) == nil)
        #expect(InstagramSystemLines.translate("lol ¯\\_(ツ)_/¯", actor: nil) == nil)
    }

    @Test func tapbackParsing() {
        #expect(Tapback.parse("Loved “see you at 8”") == Tapback(emoji: "❤️", quote: "see you at 8", removal: false))
        #expect(Tapback.parse("Laughed at “a”")?.emoji == "😂")
        #expect(Tapback.parse("Emphasized \"a\"")?.emoji == "‼️")
        #expect(Tapback.parse("Removed a heart from “a”") == Tapback(emoji: "❤️", quote: "a", removal: true))
        #expect(Tapback.parse("Removed an exclamation from “a”")?.emoji == "‼️")
        #expect(Tapback.parse("Liked the movie") == nil)
        #expect(Tapback.parse("Loved “unterminated") == nil)
    }

    @Test func reclassifyHidesTapbacksAsReactionsAndIsIdempotent() throws {
        let t = try TestArchive(); defer { t.cleanup() }
        func m(_ ts: Int64, _ mine: Bool, _ body: String) -> String { Fixtures.sms(address: Fixtures.alice, date: ts, type: mine ? 2 : 1, body: body) }
        try t.importXML(Fixtures.file([
            m(1_500_000_000_000, true, "see you at 8"),
            m(1_500_000_100_000, false, "Loved “see you at 8”"),
            m(1_500_000_200_000, false, "Removed a heart from “see you at 8”"),
            m(1_500_000_300_000, false, "Liked “see  you at&#10;8”"),            // whitespace differs
            m(1_500_000_400_000, false, "Laughed at “a message the archive never had”"),
        ]), name: "tap.xml")
        let r = try Reclassifier.run(db: t.db)
        #expect(r.tapbackExamined == 4 && r.tapbackResolved == 2 && r.tapbackRemovalsApplied == 1 && r.tapbackUnresolved == 1)
        #expect(try t.db.scalarInt("SELECT count(*) FROM reaction") == 1)                       // the heart came and went; the like stays
        #expect(try t.db.scalarString("SELECT emoji FROM reaction") == "👍")
        #expect(try t.db.scalarInt("SELECT count(*) FROM message WHERE canonical_id IS NULL AND kind IS NULL") == 1)   // only the real message
        #expect(try t.db.scalarString("SELECT kind FROM message WHERE note LIKE 'Laughed%'") == "system")
        let again = try Reclassifier.run(db: t.db)
        #expect(again.tapbackExamined == 0 && again.igExamined == 0)
    }
}
