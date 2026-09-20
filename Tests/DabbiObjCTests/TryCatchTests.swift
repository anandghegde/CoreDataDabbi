import DabbiObjC
import Foundation
import Testing

@Suite struct TryCatchTests {
    @Test func returnsTrueWhenNothingIsRaised() {
        var error: NSError?
        var ran = false
        #expect(DBTryCatch({ ran = true }, &error))
        #expect(ran)
        #expect(error == nil)
    }

    @Test func convertsAnExceptionIntoAnError() throws {
        var error: NSError?
        let completed = DBTryCatch({ _ = NSArray().object(at: 5) }, &error)
        #expect(!completed)
        let caught = try #require(error)
        #expect(caught.domain == DBExceptionErrorDomain)
        #expect(caught.userInfo[DBExceptionNameKey] as? String == NSExceptionName.rangeException.rawValue)
        #expect((caught.userInfo[DBExceptionReasonKey] as? String)?.isEmpty == false)
    }

    @Test func toleratesANilErrorPointer() {
        #expect(!DBTryCatch({ _ = NSArray().object(at: 5) }, nil))
    }
}
