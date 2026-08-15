package dev.rift.app

import android.media.session.PlaybackState
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidMediaSessionObserverTest {
    @Test
    fun combinedPlayPauseActionPublishesBothCapabilities() {
        val actions = PlaybackState.ACTION_PLAY_PAUSE

        assertTrue(AndroidMediaSessionObserver.canPlay(actions))
        assertTrue(AndroidMediaSessionObserver.canPause(actions))
    }
}
