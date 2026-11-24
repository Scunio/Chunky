import SwiftUI

/// Floating reader cards: "Go to page", end-of-comic "continue with…" confirmation and the
/// remote-progress banner. Split out of ReaderView.swift to keep `ReaderContentView`'s
/// body under SwiftLint's `type_body_length`.
extension ReaderContentView {
    /// Card to jump directly to a specific page, opened from the header's "..." menu.
    /// `.card`'s tvOS focus halo is sized by the system, not by a button's own background/corner
    /// radius — with a plain style it still draws a halo that can bleed into a tightly-spaced
    /// sibling. Shared by `pageJumpCard` and `nextComicConfirmation`, whose "Annulla"/conferma
    /// button pairs are the same shape.
    private var readerCardButtonSpacing: CGFloat {
        #if os(tvOS)
        24
        #else
        12
        #endif
    }

    func pageJumpCard(provider: ComicPageProvider) -> some View {
        VStack(spacing: 16) {
            Text("Vai a pagina")
                .font(.headline)
                .foregroundColor(.white)

            // `Stepper` doesn't exist on tvOS: two plain buttons do the same job there.
            #if os(tvOS)
            // ±10 next to ±1: one press per page made a 200-page comic practically
            // unjumpable with the remote.
            HStack(spacing: 20) {
                Button(action: { jumpPageNumber = max(1, jumpPageNumber - 10) }) {
                    Text("-10")
                }
                .accessibilityLabel(Text("Indietro di 10 pagine"))
                .focused($readerFocus, equals: .dialogStep(-10))
                Button(action: { jumpPageNumber = max(1, jumpPageNumber - 1) }) {
                    Image(systemName: "minus.circle")
                }
                .accessibilityLabel(Text("Pagina precedente"))
                .focused($readerFocus, equals: .dialogStep(-1))
                Text("Pagina \(jumpPageNumber) di \(provider.pageCount)")
                    .foregroundColor(.white)
                    .monospacedDigit()
                Button(action: { jumpPageNumber = min(max(provider.pageCount, 1), jumpPageNumber + 1) }) {
                    Image(systemName: "plus.circle")
                }
                .accessibilityLabel(Text("Pagina successiva"))
                .focused($readerFocus, equals: .dialogStep(1))
                Button(action: { jumpPageNumber = min(max(provider.pageCount, 1), jumpPageNumber + 10) }) {
                    Text("+10")
                }
                .accessibilityLabel(Text("Avanti di 10 pagine"))
                .focused($readerFocus, equals: .dialogStep(10))
            }
            .padding(.horizontal, 8)
            #else
            Stepper(value: $jumpPageNumber, in: 1...max(provider.pageCount, 1)) {
                Text("Pagina \(jumpPageNumber) di \(provider.pageCount)")
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 8)
            #endif

            HStack(spacing: readerCardButtonSpacing) {
                Button(action: {
                    isPageJumpPresented = false
                    #if os(tvOS)
                    readerFocus = .pager
                    // See the identical fix on `nextComicConfirmation`'s Annulla for why.
                    isAwaitingPagerReturn = true
                    #endif
                }) {
                    Text("Annulla")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, readerCardButtonVerticalPadding)
                        #if !os(tvOS)
                        .background(Color.white.opacity(0.15))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        #endif
                }
                #if os(tvOS)
                .focused($readerFocus, equals: .dialogCancel)
                #endif
                #if !os(tvOS)
                .keyboardShortcut(.cancelAction)
                #endif
                Button(action: confirmPageJump) {
                    Text("Vai")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, readerCardButtonVerticalPadding)
                        #if !os(tvOS)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        #endif
                }
                #if os(tvOS)
                .focused($readerFocus, equals: .dialogConfirm)
                .tint(.accentColor)
                #endif
                #if !os(tvOS)
                .keyboardShortcut(.defaultAction)
                #endif
            }
            #if os(tvOS)
            .buttonStyle(.card)
            #else
            .buttonStyle(PlainButtonStyle())
            #endif
        }
        .padding(readerCardPadding)
        .frame(maxWidth: readerCardMaxWidth)
        .background(readerCardBackground)
        .cornerRadius(16)
    }

    /// Confirmation card shown at the end of reading: explicitly asks whether to open the
    /// next comic in the library, showing its cover and title before proceeding.
    func nextComicConfirmation(_ next: ComicEntity) -> some View {
        VStack(spacing: 16) {
            Text("Fine del fumetto")
                #if os(tvOS)
                .font(.title2.bold())
                #else
                .font(.headline)
                #endif
                .foregroundColor(.white)

            HStack(spacing: 12) {
                ComicCoverView(comic: next)
                    #if os(tvOS)
                    .frame(width: 180, height: 270)
                    #else
                    .frame(width: 90, height: 135)
                    #endif
                VStack(alignment: .leading, spacing: 4) {
                    Text("Continuare con:")
                        #if os(tvOS)
                        .font(.callout)
                        #else
                        .font(.caption)
                        #endif
                        .foregroundColor(.white.opacity(0.7))
                    Text(next.title ?? "")
                        #if os(tvOS)
                        .font(.title3.bold())
                        #else
                        .font(.subheadline.bold())
                        #endif
                        .foregroundColor(.white)
                        .lineLimit(2)
                }
                Spacer()
            }

            HStack(spacing: readerCardButtonSpacing) {
                Button(action: {
                    pendingNextComic = nil
                    #if os(tvOS)
                    readerFocus = .pager
                    // Dismissing a Button bound via `.focused($readerFocus, equals:)` resets
                    // `readerFocus` to nil as it leaves the tree — confirmed live via a
                    // temporary print trace: the explicit `.pager` assignment right above gets
                    // raced/overwritten, and real UIKit focus lands on some header button
                    // instead (same "bug #2" class as tvOS-design-patterns.md, just triggered
                    // by removal instead of an unbound-button hop). Rather than chase that
                    // real focus transfer (already shown unreliable for a focused Button
                    // elsewhere in this file), reuse the header's own proven fix: force the
                    // Left/Right page-turn proxy on immediately, so paging still works right
                    // away regardless of which header button silently ends up focused.
                    isAwaitingPagerReturn = true
                    #endif
                }) {
                    Text("Annulla")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, readerCardButtonVerticalPadding)
                        #if !os(tvOS)
                        .background(Color.white.opacity(0.15))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        #endif
                }
                #if os(tvOS)
                .focused($readerFocus, equals: .dialogCancel)
                #endif
                #if !os(tvOS)
                .keyboardShortcut(.cancelAction)
                #endif
                Button(action: { switchToComic(next) }) {
                    Text("Apri")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, readerCardButtonVerticalPadding)
                        #if !os(tvOS)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        #endif
                }
                #if os(tvOS)
                .focused($readerFocus, equals: .dialogConfirm)
                .tint(.accentColor)
                #endif
                #if !os(tvOS)
                .keyboardShortcut(.defaultAction)
                #endif
            }
            #if os(tvOS)
            .buttonStyle(.card)
            #else
            .buttonStyle(PlainButtonStyle())
            #endif
        }
        .padding(readerCardPadding)
        .frame(maxWidth: readerCardMaxWidth)
        .background(readerCardBackground)
        .cornerRadius(16)
    }

    /// Floating banner for `pendingRemotePage`: deliberately not an auto-jump, which
    /// would yank the page from under the user while they're actively reading on this
    /// device too. Hidden while search/panel/next-comic cards are up so the cards
    /// don't stack.
    func remotePageBanner(target: Int) -> some View {
        VStack {
            HStack(spacing: 12) {
                Image(systemName: "icloud.and.arrow.down")
                Text("Pagina \(target + 1) su un altro dispositivo")
                    .font(.subheadline)
                    .lineLimit(1)
                Button("Vai") { jumpToRemotePage() }
                    .font(.subheadline.bold())
                Button(action: {
                    pendingRemotePage = nil
                    #if os(tvOS)
                    readerFocus = .pager
                    isAwaitingPagerReturn = true
                    #endif
                }) {
                    Image(systemName: "xmark")
                        .font(.footnote.bold())
                }
                .accessibilityLabel("Ignora")
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.85))
            .cornerRadius(20)
            // The reader fills the screen edge to edge on iOS, so a fixed 8pt inset
            // puts this banner under the status bar and on top of the header pill.
            // When the controls are visible, place it just below the measured header;
            // otherwise keep it below the status bar. The measured height also adapts
            // to iPad and landscape layouts where the header can be taller.
            #if os(iOS)
            .padding(.top, isControlsVisible
                     ? headerHeight + 8
                     : PlatformSafeArea.statusBarHeight + 8)
            #else
            .padding(.top, 8)
            #endif
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(true)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
