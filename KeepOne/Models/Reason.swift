import Foundation

/// A human-readable piece of evidence. Every recommendation and every keeper choice carries these.
struct Reason: Codable, Sendable, Hashable, Identifiable {
    var code: ReasonCode
    var detail: String?

    init(_ code: ReasonCode, _ detail: String? = nil) {
        self.code = code
        self.detail = detail
    }

    var id: String { code.rawValue + (detail ?? "") }

    var text: String {
        if let detail, !detail.isEmpty { return code.title + " · " + detail }
        return code.title
    }
}

enum ReasonCode: String, Codable, Sendable {
    // Duplicates
    case byteIdentical, visuallyIdentical, smallerCopy, duplicateOfKeeper
    // Similar shots
    case similarShot, burstFrame, blurrierThanKeeper, worseFaces, worseExposure, lowerAesthetics, lowerResolution
    // Keeper explanations
    case sharpest, bestFaces, bestExposure, bestAesthetics, favorite, edited, highestResolution
    case originalCopy, hasLocation, userChosen, manuallyProtected, sameScene, eyesOpen, wellFramed
    // Quality
    case nearlyBlack, overexposed, blankFrame, severeBlur, motionBlur, smudgedLens, accidentalShot, lowInformation
    // Temporary references
    case receiptLooking, receiptText, parkingLooking, parkingMarker, productLabelLooking, serialInfo, priceTagLooking
    case qrCode, barcode, ticketLooking, datePassed, shippingLabel, menuLooking, screenPhoto, errorMessage
    case documentLooking, referenceLooking, utilityImage
    // Context
    case olderThanRule, age, noPeople, hasPeople, uniqueMoment, possibleEvidence, lowConfidence
    case screenshot, screenshotTemporaryInfo, screenRecording
    case largeVideo, shortVideo, darkVideo, shakyVideo, duplicateVideo, similarVideo
    case downloadedImage, messagingApp, memeLooking
    case personalized, lowTrust, mayMatterForWarranty

    var title: String {
        switch self {
        case .byteIdentical: "Byte-for-byte identical copy"
        case .visuallyIdentical: "Visually identical copy"
        case .smallerCopy: "Lower-resolution copy"
        case .duplicateOfKeeper: "Same image as the one being kept"
        case .similarShot: "Similar shot of the same moment"
        case .burstFrame: "Extra burst frame"
        case .blurrierThanKeeper: "Blurrier than the recommended shot"
        case .worseFaces: "Faces look better in the recommended shot"
        case .worseExposure: "Worse exposure than the recommended shot"
        case .lowerAesthetics: "Less pleasing composition"
        case .lowerResolution: "Lower resolution"
        case .sharpest: "Sharpest in the group"
        case .bestFaces: "Best face quality"
        case .bestExposure: "Best exposure"
        case .bestAesthetics: "Highest aesthetic score"
        case .favorite: "Marked as Favorite"
        case .edited: "You edited this photo"
        case .highestResolution: "Highest resolution"
        case .originalCopy: "The original, oldest copy"
        case .hasLocation: "Keeps location data"
        case .userChosen: "Chosen by you"
        case .manuallyProtected: "Protected by you"
        case .sameScene: "Same moment as the others"
        case .eyesOpen: "Faces clearly visible"
        case .wellFramed: "Nobody cut off at the edge"
        case .nearlyBlack: "Almost completely dark"
        case .overexposed: "Severely overexposed"
        case .blankFrame: "Almost no detail — lens may have been covered"
        case .severeBlur: "Badly blurred"
        case .motionBlur: "Strong motion blur"
        case .smudgedLens: "Lens looks smudged"
        case .accidentalShot: "Looks accidental (floor, ceiling or pocket)"
        case .lowInformation: "No clear subject"
        case .receiptLooking: "Looks like a receipt"
        case .receiptText: "Receipt text detected"
        case .parkingLooking: "Looks like a parking reference"
        case .parkingMarker: "Parking marker detected"
        case .productLabelLooking: "Looks like a device or product label"
        case .serialInfo: "Contains model or serial information"
        case .priceTagLooking: "Looks like a price tag or store shelf"
        case .qrCode: "Contains a QR code"
        case .barcode: "Contains a barcode"
        case .ticketLooking: "Looks like a ticket or reservation"
        case .datePassed: "Date on it has passed"
        case .shippingLabel: "Looks like a shipping label"
        case .menuLooking: "Looks like a menu or sign"
        case .screenPhoto: "Photo of a screen"
        case .errorMessage: "Shows an error message"
        case .documentLooking: "Looks like a note or document"
        case .referenceLooking: "Looks like a quick reference photo"
        case .utilityImage: "Utility image rather than a memory"
        case .olderThanRule: "Older than your rule"
        case .age: "Taken"
        case .noPeople: "No people in it"
        case .hasPeople: "Contains people"
        case .uniqueMoment: "Unique moment — no similar shot"
        case .possibleEvidence: "May be damage or insurance evidence"
        case .lowConfidence: "KeepOne isn't sure"
        case .screenshot: "Screenshot"
        case .screenshotTemporaryInfo: "Screenshot of temporary information"
        case .screenRecording: "Screen recording"
        case .largeVideo: "Large video"
        case .shortVideo: "Very short clip"
        case .darkVideo: "Mostly dark"
        case .shakyVideo: "Very shaky or blurry"
        case .duplicateVideo: "Copy of another video"
        case .similarVideo: "Another take of the same scene"
        case .downloadedImage: "Saved from the web or an app"
        case .messagingApp: "Saved from a messaging app"
        case .memeLooking: "Looks like a meme or shared post"
        case .personalized: "You usually remove items like this"
        case .lowTrust: "You often keep these, so it's only shown for review"
        case .mayMatterForWarranty: "May matter for warranty, returns or taxes"
        }
    }

    var symbol: String {
        switch self {
        case .byteIdentical, .visuallyIdentical, .duplicateOfKeeper: "equal.square"
        case .smallerCopy, .lowerResolution: "arrow.down.right.and.arrow.up.left"
        case .similarShot, .sameScene: "square.stack"
        case .burstFrame: "square.stack.3d.forward.dottedline"
        case .blurrierThanKeeper, .severeBlur, .motionBlur: "camera.metering.unknown"
        case .worseFaces, .bestFaces, .eyesOpen: "face.smiling"
        case .worseExposure, .bestExposure: "sun.max"
        case .lowerAesthetics, .bestAesthetics: "sparkles"
        case .sharpest: "scope"
        case .favorite: "heart.fill"
        case .edited: "slider.horizontal.3"
        case .highestResolution: "arrow.up.left.and.arrow.down.right"
        case .originalCopy: "clock.arrow.circlepath"
        case .hasLocation: "location"
        case .userChosen: "hand.tap"
        case .manuallyProtected: "lock.fill"
        case .wellFramed: "crop"
        case .nearlyBlack, .darkVideo: "moon"
        case .overexposed: "sun.max.trianglebadge.exclamationmark"
        case .blankFrame, .lowInformation: "square.dashed"
        case .smudgedLens: "drop"
        case .accidentalShot: "hand.raised"
        case .receiptLooking, .receiptText: "receipt"
        case .parkingLooking, .parkingMarker: "parkingsign"
        case .productLabelLooking, .serialInfo: "barcode.viewfinder"
        case .priceTagLooking: "tag"
        case .qrCode: "qrcode"
        case .barcode: "barcode"
        case .ticketLooking: "ticket"
        case .datePassed: "calendar.badge.checkmark"
        case .shippingLabel: "shippingbox"
        case .menuLooking: "menucard"
        case .screenPhoto: "display"
        case .errorMessage: "exclamationmark.triangle"
        case .documentLooking: "doc.text"
        case .referenceLooking, .utilityImage: "pin"
        case .olderThanRule, .age: "calendar"
        case .noPeople: "person.slash"
        case .hasPeople: "person.2"
        case .uniqueMoment: "star"
        case .possibleEvidence: "exclamationmark.shield"
        case .lowConfidence: "questionmark.circle"
        case .screenshot, .screenshotTemporaryInfo: "iphone"
        case .screenRecording: "record.circle"
        case .largeVideo: "externaldrive"
        case .shortVideo: "timer"
        case .shakyVideo: "waveform.path"
        case .duplicateVideo, .similarVideo: "film.stack"
        case .downloadedImage, .messagingApp, .memeLooking: "square.and.arrow.down"
        case .personalized: "person.crop.circle.badge.checkmark"
        case .lowTrust: "hand.thumbsup.slash"
        case .mayMatterForWarranty: "checkmark.shield"
        }
    }

    /// True for reasons that argue for *keeping* (shown with a different symbol tint, never colour alone).
    var isCaution: Bool {
        switch self {
        case .hasPeople, .uniqueMoment, .possibleEvidence, .lowConfidence, .lowTrust, .mayMatterForWarranty: true
        default: false
        }
    }
}
