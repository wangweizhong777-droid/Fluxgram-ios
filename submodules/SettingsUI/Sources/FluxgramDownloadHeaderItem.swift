import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI

final class FluxgramDownloadHeaderItem: ListViewItem, ItemListItem {
    let presentationData: ItemListPresentationData
    let summary: String
    let filters: [String]
    let selectedFilter: Int
    let sectionId: ItemListSectionId
    let selectFilter: (Int) -> Void

    init(presentationData: ItemListPresentationData, summary: String, filters: [String], selectedFilter: Int, sectionId: ItemListSectionId, selectFilter: @escaping (Int) -> Void) {
        self.presentationData = presentationData
        self.summary = summary
        self.filters = filters
        self.selectedFilter = selectedFilter
        self.sectionId = sectionId
        self.selectFilter = selectFilter
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

private final class FluxgramDownloadHeaderItemNode: ListViewItemNode {
    private let title = UILabel()
    private let summary = UILabel()
    private let searchContainer = UIView()
    private let searchIcon = UIImageView()
    private let searchLabel = UILabel()
    private let searchFilterIcon = UIImageView()
    private let filterContainer = UIView()
    private let selectedFilterView = UIView()
    private let filterButtons: [UIButton] = (0 ..< 4).map { _ in UIButton(type: .system) }
    private let addButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)
    private var selectFilter: ((Int) -> Void)?
    init() {
        super.init(layerBacked: false)
        self.backgroundColor = .clear
        title.text = "下载"
        title.font = UIFont.systemFont(ofSize: 36, weight: .bold)
        title.textColor = .label
        summary.font = UIFont.systemFont(ofSize: 16)
        summary.textColor = .secondaryLabel
        searchContainer.backgroundColor = UIColor.systemGray5.withAlphaComponent(0.72)
        searchContainer.layer.cornerRadius = 15
        searchIcon.image = UIImage(systemName: "magnifyingglass")
        searchIcon.tintColor = .secondaryLabel
        searchIcon.contentMode = .scaleAspectFit
        searchLabel.text = "搜索下载任务、文件名或链接"
        searchLabel.font = UIFont.systemFont(ofSize: 15)
        searchLabel.textColor = .secondaryLabel
        searchFilterIcon.image = UIImage(systemName: "slider.horizontal.3")
        searchFilterIcon.tintColor = .secondaryLabel
        searchFilterIcon.contentMode = .scaleAspectFit
        filterContainer.backgroundColor = UIColor.systemGray6
        filterContainer.layer.cornerRadius = 21
        selectedFilterView.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
        selectedFilterView.layer.cornerRadius = 17
        for (index, button) in filterButtons.enumerated() {
            button.tag = index
            button.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .regular)
            button.addTarget(self, action: #selector(filterPressed(_:)), for: .touchUpInside)
        }
        addButton.setTitle("+", for: .normal)
        moreButton.setTitle("…", for: .normal)
        for button in [addButton, moreButton] {
            button.titleLabel?.font = UIFont.systemFont(ofSize: 24, weight: .regular)
            button.setTitleColor(.secondaryLabel, for: .normal)
            button.backgroundColor = UIColor.systemGray6.withAlphaComponent(0.72)
            button.layer.cornerRadius = 19
        }
    }
    override func didLoad() {
        super.didLoad()
        view.addSubview(title)
        view.addSubview(summary)
        view.addSubview(addButton); view.addSubview(moreButton)
        view.addSubview(searchContainer)
        searchContainer.addSubview(searchIcon)
        searchContainer.addSubview(searchLabel)
        searchContainer.addSubview(searchFilterIcon)
        view.addSubview(filterContainer)
        filterContainer.addSubview(selectedFilterView)
        for button in filterButtons { filterContainer.addSubview(button) }
    }

    @objc private func filterPressed(_ sender: UIButton) {
        self.selectFilter?(sender.tag)
    }
    func layout(item: FluxgramDownloadHeaderItem, params: ListViewItemLayoutParams) -> ListViewItemNodeLayout {
        return ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: 174), insets: UIEdgeInsets(top: 0, left: 0, bottom: 4, right: 0))
    }
    func apply(item: FluxgramDownloadHeaderItem, params: ListViewItemLayoutParams) {
        self.selectFilter = item.selectFilter
        let originX = params.leftInset + 20.0
        let width = params.width - params.leftInset - params.rightInset - 40.0
        title.frame = CGRect(x: originX, y: 0, width: width - 100, height: 38)
        addButton.frame = CGRect(x: originX + width - 84, y: 2, width: 38, height: 38)
        moreButton.frame = CGRect(x: originX + width - 38, y: 2, width: 38, height: 38)
        summary.text = item.summary
        summary.frame = CGRect(x: originX, y: 36, width: width, height: 21)
        searchContainer.frame = CGRect(x: originX, y: 64, width: width, height: 44)
        searchIcon.frame = CGRect(x: 14, y: 12, width: 20, height: 20)
        searchFilterIcon.frame = CGRect(x: width - 34, y: 12, width: 20, height: 20)
        searchLabel.frame = CGRect(x: 46, y: 0, width: width - 92, height: 44)
        filterContainer.frame = CGRect(x: originX, y: 116, width: width, height: 42)
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
            button.setTitleColor(selected ? .systemBlue : .darkGray, for: .normal)
            button.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
        }
    }
}
