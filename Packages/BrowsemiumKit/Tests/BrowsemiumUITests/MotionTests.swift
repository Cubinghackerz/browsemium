import BrowsemiumUI
import Testing

@Test
func reduceMotionTurnsEveryChromeAnimationOff() {
    #expect(BrowserMotion.standard(reduceMotion: true) == nil)
    #expect(BrowserMotion.overlay(reduceMotion: true) == nil)
    #expect(BrowserMotion.quick(reduceMotion: true) == nil)
}

@Test
func withMotionOnEachRoleAnimates() {
    #expect(BrowserMotion.standard(reduceMotion: false) != nil)
    #expect(BrowserMotion.overlay(reduceMotion: false) != nil)
    #expect(BrowserMotion.quick(reduceMotion: false) != nil)
}
