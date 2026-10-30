//
//  ZLImageNavController.swift
//  ZLPhotoBrowser
//
//  Created by long on 2020/8/18.
//
//  Copyright (c) 2020 Long Zhang <495181165@qq.com>
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

import UIKit
import Photos

public class ZLImageNavController: UINavigationController {
    // Luna Sync: allow a SwiftUI navigation destination to own cancellation.
    public var handlesCancellationInHost = false
    public var selectionAccessoryView: UIView?
    public var selectionBusyChanged: ((Bool) -> Void)?
    public var selectedAssetIdentifiers: Set<String> { Set(arrSelectedModels.map { $0.asset.localIdentifier }) }
    func cancelPicker() {
        if handlesCancellationInHost { cancelBlock?() }
        else { dismiss(animated: true) { [weak self] in self?.cancelBlock?() } }
    }

    public func currentAlbumFetchResult() -> PHFetchResult<PHAsset>? {
        viewControllers.compactMap { $0 as? ZLThumbnailViewController }.last?.fetchResultForRangeSelection
    }

    /// Build large selections off the UI thread. Only publish the completed
    /// array, so cells and Done always see a consistent selection.
    @available(iOS 13.0, *)
    @MainActor public func replaceSelectionInBackground(with assets: [PHAsset]) async {
        let worker = Task.detached(priority: .userInitiated) {
            var models: [ZLPhotoModel] = []
            models.reserveCapacity(assets.count)
            var seen: Set<String> = []
            for asset in assets {
                try Task.checkCancellation()
                if seen.insert(asset.localIdentifier).inserted {
                    autoreleasepool {
                        let model = ZLPhotoModel(asset: asset)
                        model.isSelected = true
                        models.append(model)
                    }
                }
            }
            return models
        }
        guard let models = try? await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() }), !Task.isCancelled else { return }
        arrSelectedModels.forEach { $0.isSelected = false }
        arrSelectedModels = models
        synchronizeSelectionViews()
    }

    @available(iOS 13.0, *)
    @MainActor public func setSelectionBusy(_ busy: Bool) {
        selectionBusyChanged?(busy)
        view.isUserInteractionEnabled = !busy
        if busy {
            guard selectionSpinner == nil else { return }
            let spinner = UIActivityIndicatorView(style: .large)
            spinner.backgroundColor = .secondarySystemBackground
            spinner.layer.cornerRadius = 12
            spinner.frame = CGRect(x: view.bounds.midX - 36, y: view.bounds.midY - 36, width: 72, height: 72)
            spinner.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
            view.addSubview(spinner); spinner.startAnimating()
            selectionSpinner = spinner
        } else { selectionSpinner?.removeFromSuperview(); selectionSpinner = nil }
    }

    private var selectionSpinner: UIActivityIndicatorView?
    // Luna Sync addition (2026): expand endpoint selections without replacing
    // the upstream grid, paging or previews. The Done button uses the real count.
    public func currentAlbumAssets() -> [PHAsset] {
        viewControllers.compactMap { $0 as? ZLThumbnailViewController }.last?.assetsForRangeSelection() ?? []
    }

    public func replaceSelection(with assets: [PHAsset]) {
        let old = Dictionary(arrSelectedModels.map { ($0.ident, $0) }, uniquingKeysWith: { first, _ in first })
        arrSelectedModels.forEach { $0.isSelected = false }
        var seen: Set<String> = []
        arrSelectedModels = assets.compactMap { asset in
            guard seen.insert(asset.localIdentifier).inserted else { return nil }
            let model = old[asset.localIdentifier] ?? ZLPhotoModel(asset: asset)
            model.isSelected = true
            return model
        }
        synchronizeSelectionViews()
    }

    private func synchronizeSelectionViews() {
        for controller in viewControllers {
            (controller as? ZLThumbnailViewController)?.synchronizeExternalSelection()
            (controller as? ZLPhotoPreviewController)?.synchronizeExternalSelection()
        }
    }

    var isSelectedOriginal = false
    
    var arrSelectedModels: [ZLPhotoModel] = [] {
        didSet { selectionIndexDirty = true }
    }
    private var selectionIndexDirty = true
    private var selectionIndices: [String: Int] = [:]

    func selectedIndex(for identifier: String) -> Int? {
        if selectionIndexDirty {
            selectionIndices = Dictionary(arrSelectedModels.enumerated().map { ($0.element.ident, $0.offset) }, uniquingKeysWith: { first, _ in first })
            selectionIndexDirty = false
        }
        return selectionIndices[identifier]
    }
    
    var selectImageBlock: (() -> Void)?
    
    var cancelBlock: (() -> Void)?
    
    deinit {
        zl_debugPrint("ZLImageNavController deinit")
    }
    
    public override var preferredStatusBarStyle: UIStatusBarStyle {
        return ZLPhotoUIConfiguration.default().statusBarStyle
    }
    
    public override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        if deviceIsiPad() {
            .all
        } else {
            ZLPhotoUIConfiguration.default().supportLandscape ? .all : .portrait
        }
    }
    
    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nil, bundle: nil)
    }
    
    override init(rootViewController: UIViewController) {
        super.init(rootViewController: rootViewController)
        navigationBar.barStyle = .black
        navigationBar.isTranslucent = true
        modalPresentationStyle = .fullScreen
        isNavigationBarHidden = true
    }
    
    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func viewDidLoad() {
        super.viewDidLoad()

        // Do any additional setup after loading the view.
    }
}
