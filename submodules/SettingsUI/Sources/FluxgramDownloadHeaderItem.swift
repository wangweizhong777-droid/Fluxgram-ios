import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI

/// Shared visual tokens for the downloads screen. Keeping these values in one
/// place prevents the header and task cards from drifting apart while leaving
/// the existing list structure and download behavior untouched.
enum FluxgramDownloadDesign {
    enum Spacing {
        static let xSmall: CGFloat = 4.0
        static let small: CGFloat = 8.0
        static let medium: CGFloat = 12.0
        static let large: CGFloat = 16.0
        static let pageMargin: CGFloat = 20.0
    }

    enum Font {
        static let pageTitle = UIFont.systemFont(ofSize: 34.0, weight: .bold)
        static let summary = UIFont.systemFont(ofSize: 15.0, weight: .regular)
        static let filter = UIFont.systemFont(ofSize: 13.0, weight: .regular)
        static let selectedFilter = UIFont.systemFont(ofSize: 13.0, weight: .medium)
        static let search = UIFont.systemFont(ofSize: 15.0, weight: .regular)
        static let fileName = UIFont.systemFont(ofSize: 16.5, weight: .semibold)
        static let metadata = UIFont.systemFont(ofSize: 13.5, weight: .regular)
        static let progress = UIFont.monospacedDigitSystemFont(ofSize: 13.5, weight: .semibold)
    }

    enum Surface {
        static let page = UIColor.systemGroupedBackground
        static let control = UIColor.systemGray5
        static let card = UIColor.systemBackground
        static let subtleAction = UIColor.systemGray6
    }

    enum Size {
        static let cardAction: CGFloat = 40.0
        static let moreHitArea: CGFloat = 32.0
        static let statusIcon: CGFloat = 16.0
        static let cardRadius: CGFloat = 20.0
    }

    static let regularSymbol = UIImage.SymbolConfiguration(pointSize: 15.0, weight: .medium)
    static let subtleSymbol = UIImage.SymbolConfiguration(pointSize: 14.0, weight: .medium)
    static let statusSymbol = UIImage.SymbolConfiguration(pointSize: 15.0, weight: .medium)
}

final class FluxgramDownloadHeaderItem: ListViewItem, ItemListItem {
    let presentationData: ItemListPresentationData
    let summary: String
    let filters: [String]
    let selectedFilter: Int
    let searchQuery: String
    let sectionId: ItemListSectionId
    let selectFilter: (Int) -> Void
    let updateSearchQuery: (String) -> Void

    init(presentationData: ItemListPresentationData, summary: String, filters: [String], selectedFilter: Int, searchQuery: String, sectionId: ItemListSectionId, selectFilter: @escaping (Int) -> Void, updateSearchQuery: @escaping (String) -> Void) {
        self.presentationData = presentationData
        self.summary = summary
        self.filters = filters
        self.selectedFilter = selectedFilter
        self.searchQuery = searchQuery
        self.sectionId = sectionId
        self.selectFilter = selectFilter
        self.updateSearchQuery = updateSearchQuery
    }
    var selectable: Bool = false
    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, previousItem: ListViewItem?, nextItem: ListViewItem?, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = FluxgramDownloadHeaderItemNode()
            let layout = node.layout(item: self, params: params)
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            Queue.mainQueue().async { completion(node, { return (nil, { _ in node.apply(item: self, params: params) }) }) }
        }
    }
    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, previousItem: ListViewItem?, nextItem: ListViewItem?, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let node = node() as? FluxgramDownloadHeaderItemNode else { return }
            let layout = node.layout(item: self, params: params)
            completion(layout, { _ in node.apply(item: self, params: params) })
        }
    }
}

private final class FluxgramDownloadHeaderItemNode: ListViewItemNode, UITextFieldDelegate {
    private let title = UILabel()
    private let summary = UILabel()
    private let searchContainer = UIView()
    private let searchIcon = UIImageView()
    private let searchField = UITextField()
    private let filterContainer = UIView()
    private let selectedFilterView = UIView()
    private let filterButtons: [UIButton] = (0 ..< 4).map { _ in UIButton(type: .system) }
    private var selectFilter: ((Int) -> Void)?
    private var updateSearchQuery: ((String) -> Void)?
    init() {
        super.init(layerBacked: false)
        self.backgroundColor = FluxgramDownloadDesign.Surface.page
        title.text = "下载"
        title.font = FluxgramDownloadDesign.Font.pageTitle
        title.textColor = .label
        summary.font = FluxgramDownloadDesign.Font.summary
        summary.textColor = .secondaryLabel
        searchContainer.backgroundColor = FluxgramDownloadDesign.Surface.control
        searchContainer.layer.cornerRadius = 15
        searchIcon.image = UIImage(systemName: "magnifyingglass", withConfiguration: FluxgramDownloadDesign.regularSymbol)
        searchIcon.tintColor = .secondaryLabel
        searchIcon.contentMode = .scaleAspectFit
        searchField.placeholder = "搜索下载任务、文件名或链接"
        searchField.font = FluxgramDownloadDesign.Font.search
        searchField.textColor = .label
        searchField.tintColor = .systemBlue
        searchField.clearButtonMode = .whileEditing
        searchField.returnKeyType = .search
        searchField.autocapitalizationType = .none
        searchField.autocorrectionType = .no
        searchField.delegate = self
        searchField.addTarget(self, action: #selector(searchTextChanged), for: .editingChanged)
        filterContainer.backgroundColor = FluxgramDownloadDesign.Surface.control
        filterContainer.layer.cornerRadius = 21
        selectedFilterView.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
        selectedFilterView.layer.cornerRadius = 17
        for (index, button) in filterButtons.enumerated() {
            button.tag = index
            button.titleLabel?.font = FluxgramDownloadDesign.Font.filter
            button.addTarget(self, action: #selector(filterPressed(_:)), for: .touchUpInside)
        }
    }
    override func didLoad() {
        super.didLoad()
        view.addSubview(title)
        view.addSubview(summary)
        view.addSubview(searchContainer)
        searchContainer.addSubview(searchIcon)
        searchContainer.addSubview(searchField)
        view.addSubview(filterContainer)
        filterContainer.addSubview(selectedFilterView)
        for button in filterButtons { filterContainer.addSubview(button) }
    }

    @objc private func filterPressed(_ sender: UIButton) {
        self.selectFilter?(sender.tag)
    }

    @objc private func searchTextChanged() {
        self.updateSearchQuery?(self.searchField.text ?? "")
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
    func layout(item: FluxgramDownloadHeaderItem, params: ListViewItemLayoutParams) -> ListViewItemNodeLayout {
        return ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: 168), insets: UIEdgeInsets(top: 0, left: 0, bottom: FluxgramDownloadDesign.Spacing.xSmall, right: 0))
    }
    func apply(item: FluxgramDownloadHeaderItem, params: ListViewItemLayoutParams) {
        self.selectFilter = item.selectFilter
        self.updateSearchQuery = item.updateSearchQuery
        let originX = params.leftInset + FluxgramDownloadDesign.Spacing.pageMargin
        let width = params.width - params.leftInset - params.rightInset - FluxgramDownloadDesign.Spacing.pageMargin * 2.0
        title.frame = CGRect(x: originX, y: 0, width: width, height: 37)
        summary.text = item.summary
        summary.frame = CGRect(x: originX, y: 35, width: width, height: 20)
        searchContainer.frame = CGRect(x: originX, y: 60, width: width, height: 44)
        searchIcon.frame = CGRect(x: 14, y: 12, width: 20, height: 20)
        searchField.frame = CGRect(x: 46, y: 0, width: width - 58, height: 44)
        if !searchField.isFirstResponder, searchField.text != item.searchQuery {
            searchField.text = item.searchQuery
        }
        filterContainer.frame = CGRect(x: originX, y: 112, width: width, height: 42)
        let segmentWidth = width / CGFloat(filterButtons.count)
        let selectedFrame = CGRect(x: CGFloat(item.selectedFilter) * segmentWidth + 4, y: 4, width: segmentWidth - 8, height: 34)
        if selectedFilterView.frame == .zero {
            selectedFilterView.frame = selectedFrame
        } else {
            UIView.animate(withDuration: 0.2) { self.selectedFilterView.frame = selectedFrame }
        }
        for (index, button) in filterButtons.enumerated() {
            button.frame = CGRect(x: CGFloat(index) * segmentWidth, y: 0, width: segmentWidth, height: 42)
            button.setTitle(index < item.filters.count ? item.filters[index] : "", for: .normal)
            let selected = index == item.selectedFilter
            button.setTitleColor(selected ? .systemBlue : .secondaryLabel, for: .normal)
            button.titleLabel?.font = selected ? FluxgramDownloadDesign.Font.selectedFilter : FluxgramDownloadDesign.Font.filter
        }
    }
}
