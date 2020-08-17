module Matterhorn.Draw.ReactionEmojiListOverlay
  ( drawReactionEmojiListOverlay
  )
where

import           Prelude ()
import           Matterhorn.Prelude

import           Brick
import           Brick.Widgets.List ( listSelectedFocusedAttr )
import qualified Data.Text as T

import           Matterhorn.Draw.Main
import           Matterhorn.Draw.ListOverlay ( drawListOverlay, OverlayPosition(..) )
import           Matterhorn.Types
import           Matterhorn.Themes


drawReactionEmojiListOverlay :: ChatState -> [Widget Name]
drawReactionEmojiListOverlay st =
    let overlay = drawListOverlay (st^.csReactionEmojiListOverlay)
                                  (const $ txt "Search Emoji")
                                  (const $ txt "No matching emoji found.")
                                  (const $ txt "Search emoji:")
                                  renderEmoji
                                  Nothing
                                  OverlayCenter
                                  80
    in joinBorders overlay : drawMain False st

renderEmoji :: Bool -> (Bool, T.Text) -> Widget Name
renderEmoji sel (mine, e) =
    let maybeForce = if sel
                     then forceAttr listSelectedFocusedAttr
                     else id
    in maybeForce $
       padRight Max $
       hBox [ if mine then txt " * " else txt "   "
            , withDefAttr emojiAttr $ txt $ ":" <> e <> ":"
            ]