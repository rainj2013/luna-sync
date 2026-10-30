import Foundation

/// Compatibility for supplemental PhotoKit resources absent from the public enum.
/// Original-media completeness is checked separately; this never supplies an original.
public enum PhotoResourceCompatibility {
    public static func isSupplementaryAdjustment(type: Int, uniformTypeIdentifier: String) -> Bool {
        // Observed alongside public.heic originals on device: type 16, IMG_*O.aae.
        // Match both fields so unrelated undocumented resource types remain reviewable.
        type == 16 && uniformTypeIdentifier == "com.apple.photos.apple-adjustment-envelope"
    }
}
