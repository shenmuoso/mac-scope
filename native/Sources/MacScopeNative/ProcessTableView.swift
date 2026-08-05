@preconcurrency import AppKit
import SwiftUI

struct ProcessTableLabels: Equatable {
  let process: String
  let pid: String
  let cpu: String
  let memory: String
  let diskRead: String
  let diskWrite: String
  let download: String
  let upload: String
  let threads: String
  let runtime: String
  let showProcessInfo: String
  let quitProcess: String
  let forceQuit: String
  let systemSoftware: String
  let installedSoftware: String
  let userTool: String
  let other: String

  init(language: AppLanguage) {
    process = AppLocalization.string("Process", language: language)
    pid = AppLocalization.string("PID", language: language)
    cpu = AppLocalization.string("CPU", language: language)
    memory = AppLocalization.string("Memory", language: language)
    diskRead = AppLocalization.string("Disk Read", language: language)
    diskWrite = AppLocalization.string("Disk Write", language: language)
    download = AppLocalization.string("Download", language: language)
    upload = AppLocalization.string("Upload", language: language)
    threads = AppLocalization.string("Threads", language: language)
    runtime = AppLocalization.string("Runtime", language: language)
    showProcessInfo = AppLocalization.string("Show Process Info", language: language)
    quitProcess = AppLocalization.string("Quit Process", language: language)
    forceQuit = AppLocalization.string("Force Quit", language: language)
    systemSoftware = AppLocalization.string("System Software or Services", language: language)
    installedSoftware = AppLocalization.string("Installed Software", language: language)
    userTool = AppLocalization.string("Plug-ins or Tools", language: language)
    other = AppLocalization.string("Other", language: language)
  }

  func title(for field: ProcessSortField) -> String {
    switch field {
    case .name: process
    case .pid: pid
    case .cpu: cpu
    case .memory: memory
    case .diskRead: diskRead
    case .diskWrite: diskWrite
    case .download: download
    case .upload: upload
    case .threads: threads
    case .runtime: runtime
    }
  }

  func originTitle(_ origin: ProcessOrigin) -> String {
    switch origin {
    case .macOSSystem: systemSoftware
    case .installedSoftware: installedSoftware
    case .userTool: userTool
    case .unknown: other
    }
  }
}

@MainActor
struct ProcessTableView: NSViewRepresentable {
  let rows: [ProcessRow]
  @Binding var selection: ProcessRow.ID?
  @Binding var sort: ProcessSortDescriptor
  let labels: ProcessTableLabels
  let onInspect: (ProcessRow) -> Void
  let onQuit: (ProcessRow) -> Void
  let onForceQuit: (ProcessRow) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeNSView(context: Context) -> ProcessTableScrollView {
    let scrollView = ProcessTableScrollView()
    context.coordinator.configure(scrollView)
    context.coordinator.update(from: self, in: scrollView, reloadRows: true)
    return scrollView
  }

  func updateNSView(_ scrollView: ProcessTableScrollView, context: Context) {
    let reloadRows = context.coordinator.rows != rows
    context.coordinator.update(from: self, in: scrollView, reloadRows: reloadRows)
  }

  @MainActor
  final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private var parent: ProcessTableView
    fileprivate var rows: [ProcessRow] = []
    private var labels: ProcessTableLabels
    private weak var tableView: NSTableView?
    private var contextPID: ProcessRow.ID?
    private var isSynchronizingSelection = false
    private var isSynchronizingSort = false

    init(parent: ProcessTableView) {
      self.parent = parent
      labels = parent.labels
    }

    func configure(_ scrollView: ProcessTableScrollView) {
      let tableView = scrollView.tableView
      self.tableView = tableView
      tableView.dataSource = self
      tableView.delegate = self
      tableView.target = self
      tableView.doubleAction = #selector(openSelectedProcess(_:))

      let menu = NSMenu()
      menu.autoenablesItems = false
      menu.delegate = self
      tableView.menu = menu

      for field in ProcessSortField.allCases {
        let column = NSTableColumn(identifier: identifier(for: field))
        column.title = labels.title(for: field)
        column.width = width(for: field)
        column.minWidth = minimumWidth(for: field)
        column.maxWidth = maximumWidth(for: field)
        column.resizingMask = .userResizingMask
        column.headerCell.alignment = field == .name ? .left : .right
        column.sortDescriptorPrototype = NSSortDescriptor(
          key: field.rawValue,
          ascending: field.defaultDirection == .ascending
        )
        tableView.addTableColumn(column)
      }
      scrollView.minimumDocumentWidth = ProcessSortField.allCases.reduce(0) {
        $0 + width(for: $1)
      }
    }

    func update(
      from parent: ProcessTableView,
      in scrollView: ProcessTableScrollView,
      reloadRows: Bool
    ) {
      self.parent = parent
      rows = parent.rows

      if labels != parent.labels {
        labels = parent.labels
        updateColumnTitles(in: scrollView.tableView)
      }
      synchronizeSort(parent.sort, in: scrollView.tableView)

      if reloadRows {
        // A process metric sort can move nearly every row. A single native reload avoids
        // SwiftUI's expensive sequence of per-row NSTableView move operations.
        isSynchronizingSelection = true
        scrollView.tableView.reloadData()
        isSynchronizingSelection = false
      }
      synchronizeSelection(parent.selection, in: scrollView.tableView)
      scrollView.updateDocumentWidth()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
      rows.count
    }

    func tableView(
      _ tableView: NSTableView,
      viewFor tableColumn: NSTableColumn?,
      row: Int
    ) -> NSView? {
      guard rows.indices.contains(row), let tableColumn,
        let field = ProcessSortField(rawValue: tableColumn.identifier.rawValue)
      else {
        return nil
      }

      let process = rows[row]
      if field == .name {
        let identifier = NSUserInterfaceItemIdentifier("ProcessIdentityCell")
        let cell =
          tableView.makeView(withIdentifier: identifier, owner: nil)
          as? ProcessIdentityTableCellView ?? ProcessIdentityTableCellView()
        cell.identifier = identifier
        cell.configure(process: process, originTitle: labels.originTitle(process.software.origin))
        return cell
      }

      let identifier = NSUserInterfaceItemIdentifier("ProcessValueCell.\(field.rawValue)")
      let cell =
        tableView.makeView(withIdentifier: identifier, owner: nil)
        as? ProcessValueTableCellView ?? ProcessValueTableCellView()
      cell.identifier = identifier
      cell.configure(value(for: field, process: process))
      return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
      guard !isSynchronizingSelection, let tableView else { return }
      let selectedRow = tableView.selectedRow
      let selectedPID = rows.indices.contains(selectedRow) ? rows[selectedRow].pid : nil
      if parent.selection != selectedPID {
        parent.selection = selectedPID
      }
    }

    func tableView(
      _ tableView: NSTableView,
      sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
    ) {
      guard !isSynchronizingSort,
        let descriptor = tableView.sortDescriptors.first,
        let key = descriptor.key,
        let field = ProcessSortField(rawValue: key)
      else {
        return
      }

      let nextSort = ProcessSortDescriptor(
        field: field,
        direction: descriptor.ascending ? .ascending : .descending
      )
      if parent.sort != nextSort {
        parent.sort = nextSort
      }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
      menu.removeAllItems()
      guard let tableView else { return }
      let clickedRow = tableView.clickedRow
      guard rows.indices.contains(clickedRow) else {
        contextPID = nil
        return
      }

      let process = rows[clickedRow]
      contextPID = process.pid
      tableView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)

      menu.addItem(
        item(title: labels.showProcessInfo, action: #selector(inspectContextProcess(_:)))
      )
      menu.addItem(.separator())
      menu.addItem(item(title: labels.quitProcess, action: #selector(quitContextProcess(_:))))
      menu.addItem(
        item(title: labels.forceQuit, action: #selector(forceQuitContextProcess(_:)))
      )
    }

    @objc private func openSelectedProcess(_ sender: NSTableView) {
      let row = sender.clickedRow >= 0 ? sender.clickedRow : sender.selectedRow
      guard rows.indices.contains(row) else { return }
      let process = rows[row]
      parent.selection = process.pid
      parent.onInspect(process)
    }

    @objc private func inspectContextProcess(_ sender: Any?) {
      guard let process = contextProcess else { return }
      parent.onInspect(process)
    }

    @objc private func quitContextProcess(_ sender: Any?) {
      guard let process = contextProcess else { return }
      parent.onQuit(process)
    }

    @objc private func forceQuitContextProcess(_ sender: Any?) {
      guard let process = contextProcess else { return }
      parent.onForceQuit(process)
    }

    private var contextProcess: ProcessRow? {
      guard let contextPID else { return nil }
      return rows.first { $0.pid == contextPID }
    }

    private func synchronizeSelection(_ selection: ProcessRow.ID?, in tableView: NSTableView) {
      let selectedRow = selection.flatMap { pid in rows.firstIndex { $0.pid == pid } } ?? -1
      guard tableView.selectedRow != selectedRow else { return }

      isSynchronizingSelection = true
      if selectedRow >= 0 {
        tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
      } else {
        tableView.deselectAll(nil)
      }
      isSynchronizingSelection = false
    }

    private func synchronizeSort(_ sort: ProcessSortDescriptor, in tableView: NSTableView) {
      if let current = tableView.sortDescriptors.first,
        current.key == sort.field.rawValue,
        current.ascending == (sort.direction == .ascending)
      {
        return
      }

      isSynchronizingSort = true
      tableView.sortDescriptors = [
        NSSortDescriptor(
          key: sort.field.rawValue,
          ascending: sort.direction == .ascending
        )
      ]
      isSynchronizingSort = false
    }

    private func updateColumnTitles(in tableView: NSTableView) {
      for column in tableView.tableColumns {
        guard let field = ProcessSortField(rawValue: column.identifier.rawValue) else { continue }
        column.title = labels.title(for: field)
      }
      tableView.headerView?.needsDisplay = true
      isSynchronizingSelection = true
      tableView.reloadData()
      isSynchronizingSelection = false
    }

    private func item(title: String, action: Selector) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
      item.target = self
      return item
    }

    private func identifier(for field: ProcessSortField) -> NSUserInterfaceItemIdentifier {
      NSUserInterfaceItemIdentifier(field.rawValue)
    }

    private func width(for field: ProcessSortField) -> CGFloat {
      switch field {
      case .name: 290
      case .pid: 70
      case .cpu: 76
      case .memory: 100
      case .diskRead, .diskWrite: 92
      case .download: 96
      case .upload: 92
      case .threads: 76
      case .runtime: 90
      }
    }

    private func minimumWidth(for field: ProcessSortField) -> CGFloat {
      field == .name ? 220 : width(for: field)
    }

    private func maximumWidth(for field: ProcessSortField) -> CGFloat {
      field == .name ? 520 : max(180, width(for: field))
    }

    private func value(for field: ProcessSortField, process: ProcessRow) -> String {
      switch field {
      case .name: process.name
      case .pid: String(process.pid)
      case .cpu: DisplayFormat.percent(process.cpuPercent)
      case .memory: DisplayFormat.bytes(process.memoryBytes)
      case .diskRead: DisplayFormat.rate(process.diskReadRate)
      case .diskWrite: DisplayFormat.rate(process.diskWriteRate)
      case .download: DisplayFormat.rate(process.networkDownloadRate)
      case .upload: DisplayFormat.rate(process.networkUploadRate)
      case .threads: String(process.threadCount)
      case .runtime: DisplayFormat.duration(process.runtime)
      }
    }
  }
}

final class ProcessTableScrollView: NSScrollView {
  let tableView = NSTableView()
  var minimumDocumentWidth: CGFloat = 0

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    drawsBackground = true
    backgroundColor = .controlBackgroundColor
    hasVerticalScroller = true
    hasHorizontalScroller = true
    autohidesScrollers = true
    scrollerStyle = .overlay
    verticalScroller?.controlSize = .small
    horizontalScroller?.controlSize = .small

    tableView.rowHeight = 42
    tableView.intercellSpacing = .zero
    tableView.columnAutoresizingStyle = .noColumnAutoresizing
    tableView.allowsColumnReordering = false
    tableView.allowsColumnResizing = true
    tableView.allowsMultipleSelection = false
    tableView.allowsEmptySelection = true
    tableView.selectionHighlightStyle = .regular
    tableView.usesAlternatingRowBackgroundColors = false
    tableView.style = .fullWidth
    documentView = tableView
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func tile() {
    super.tile()
    updateDocumentWidth()
  }

  func updateDocumentWidth() {
    let targetWidth = max(minimumDocumentWidth, contentSize.width)
    guard abs(tableView.frame.width - targetWidth) > 0.5 else { return }
    tableView.setFrameSize(NSSize(width: targetWidth, height: tableView.frame.height))
  }
}

private final class ProcessIdentityTableCellView: NSTableCellView {
  private let processIcon = NSImageView()
  private let titleLabel = NSTextField(labelWithString: "")
  private let subtitleLabel = NSTextField(labelWithString: "")
  private var templateTint: NSColor?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)

    processIcon.imageScaling = .scaleProportionallyUpOrDown
    processIcon.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    subtitleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    subtitleLabel.lineBreakMode = .byTruncatingTail
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

    addSubview(processIcon)
    addSubview(titleLabel)
    addSubview(subtitleLabel)
    NSLayoutConstraint.activate([
      processIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      processIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
      processIcon.widthAnchor.constraint(equalToConstant: 24),
      processIcon.heightAnchor.constraint(equalToConstant: 24),
      titleLabel.leadingAnchor.constraint(equalTo: processIcon.trailingAnchor, constant: 9),
      titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
      subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
      subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor),
      subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),
    ])
    updateColors()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var backgroundStyle: NSView.BackgroundStyle {
    didSet { updateColors() }
  }

  func configure(process: ProcessRow, originTitle: String) {
    titleLabel.stringValue = process.name
    titleLabel.toolTip = process.name
    if process.software.name.caseInsensitiveCompare(process.name) == .orderedSame {
      subtitleLabel.stringValue = originTitle
    } else {
      subtitleLabel.stringValue = "\(process.software.name) · \(originTitle)"
    }

    if let bundleURL = process.software.bundleURL {
      processIcon.image = WorkspaceIconCache.icon(for: bundleURL)
      templateTint = nil
    } else {
      let symbolName: String
      switch process.software.origin {
      case .macOSSystem: symbolName = "gearshape.2.fill"
      case .installedSoftware: symbolName = "app.fill"
      case .userTool: symbolName = "terminal.fill"
      case .unknown: symbolName = "questionmark.circle"
      }
      let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
      processIcon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration)
      switch process.software.origin {
      case .macOSSystem, .unknown: templateTint = .secondaryLabelColor
      case .installedSoftware: templateTint = .controlAccentColor
      case .userTool: templateTint = .systemOrange
      }
    }
    updateColors()
  }

  private func updateColors() {
    let isSelected = backgroundStyle == .emphasized
    titleLabel.textColor = isSelected ? .alternateSelectedControlTextColor : .labelColor
    subtitleLabel.textColor =
      isSelected
      ? .alternateSelectedControlTextColor.withAlphaComponent(0.72) : .secondaryLabelColor
    processIcon.contentTintColor =
      isSelected && templateTint != nil
      ? .alternateSelectedControlTextColor : templateTint
  }
}

private final class ProcessValueTableCellView: NSTableCellView {
  private let valueLabel = NSTextField(labelWithString: "")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    valueLabel.alignment = .right
    valueLabel.font = .monospacedDigitSystemFont(
      ofSize: NSFont.systemFontSize,
      weight: .regular
    )
    valueLabel.lineBreakMode = .byTruncatingTail
    valueLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(valueLabel)
    NSLayoutConstraint.activate([
      valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
      valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    updateColors()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var backgroundStyle: NSView.BackgroundStyle {
    didSet { updateColors() }
  }

  func configure(_ value: String) {
    valueLabel.stringValue = value
    valueLabel.toolTip = value
    updateColors()
  }

  private func updateColors() {
    valueLabel.textColor =
      backgroundStyle == .emphasized
      ? .alternateSelectedControlTextColor : .labelColor
  }
}
