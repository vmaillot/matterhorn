{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}

{-|

The 'Message' is a single displayed event in a Channel.  All Messages
have a date/time, and messages that represent posts to the channel
have a (hash) ID, and displayable text, along with other attributes.

All Messages are sorted chronologically.  There is no assumption that
the server date/time is synchronized with the local date/time, so all
of the Message ordering uses the server's date/time.

The mattermost-api retrieves a 'Post' from the server, briefly encodes
the useful portions of that as a 'ClientPost' object and then converts
it to a 'Message' inserting this result it into the collection of
Messages associated with a Channel.  The PostID of the message
uniquely identifies that message and can be used to interact with the
server for subsequent operations relative to that message's 'Post'.
The date/time associated with these messages is generated by the
server.

There are also "messages" generated directly by the Matterhorn client
which can be used to display additional, client-related information to
the user. Examples of these client messages are: date boundaries, the
"new messages" marker, errors from invoking the browser, etc.  These
client-generated messages will have a date/time although it is locally
generated (usually by relation to an associated Post).

Most other Matterhorn operations primarily are concerned with
user-posted messages (@case mMessageId of Just _@ or @case mType of CP
_@), but others will include client-generated messages (@case mMessageId
of Nothing@ or @case mType of C _@).

--}

module Types.Messages
  ( -- * Message and operations on a single Message
    Message(..)
  , isDeletable, isReplyable, isEditable, isReplyTo, isGap, isFlaggable
  , isEmote, isJoinLeave, isTransition
  , mText, mUser, mDate, mType, mPending, mDeleted
  , mAttachments, mInReplyToMsg, mMessageId, mReactions, mFlagged
  , mOriginalPost, mChannelId, mMarkdownSource
  , MessageType(..)
  , MessageId(..)
  , ThreadState(..)
  , isPostMessage
  , messagePostId
  , messageIdPostId
  , UserRef(..)
  , ReplyState(..)
  , clientMessageToMessage
  , clientPostToMessage
  , newMessageOfType
    -- * Message Collections
  , Messages
  , ChronologicalMessages
  , RetrogradeMessages
  , MessageOps (..)
  , noMessages
  , filterMessages
  , reverseMessages
  , unreverseMessages
    -- * Operations on Posted Messages
  , splitMessages
  , splitDirSeqOn
  , findMessage
  , getRelMessageId
  , getNextMessage
  , getPrevMessage
  , getNextMessageId
  , getPrevMessageId
  , getNextPostId
  , getPrevPostId
  , getEarliestPostMsg
  , getLatestPostMsg
  , getEarliestSelectableMessage
  , getLatestSelectableMessage
  , findLatestUserMessage
  -- * Operations on any Message type
  , messagesAfter
  , removeMatchesFromSubset
  , withFirstMessage
  , msgURLs
  , altInlinesString

  , LinkChoice(LinkChoice)
  , linkUser
  , linkURL
  , linkTime
  , linkName
  , linkFileId
  )
where

import           Prelude ()
import           Prelude.MH

import           Cheapskate ( Blocks )
import qualified Cheapskate as C
import           Control.Monad
import qualified Data.Foldable as F
import           Data.Hashable ( Hashable )
import qualified Data.Map.Strict as Map
import           Data.Sequence as Seq
import qualified Data.Set as S
import           Data.Tuple
import           Data.UUID ( UUID )
import           GHC.Generics ( Generic )
import           Lens.Micro.Platform ( makeLenses )

import           Network.Mattermost.Types ( ChannelId, PostId, Post
                                          , ServerTime, UserId, FileId )

import           Types.DirectionalSeq
import           Types.Posts
import           Types.UserNames


data ThreadState =
    NoThread
    | InThreadShowParent
    | InThread
    deriving (Show, Eq)

-- ----------------------------------------------------------------------
-- * Messages

data MessageId = MessagePostId PostId
               | MessageUUID UUID
               deriving (Eq, Read, Show, Generic, Hashable)

messageIdPostId :: MessageId -> Maybe PostId
messageIdPostId (MessagePostId p) = Just p
messageIdPostId _ = Nothing

-- | A 'Message' is any message we might want to render, either from
--   Mattermost itself or from a client-internal source.
data Message = Message
  { _mText          :: Blocks
  , _mMarkdownSource :: Text
  , _mUser          :: UserRef
  , _mDate          :: ServerTime
  , _mType          :: MessageType
  , _mPending       :: Bool
  , _mDeleted       :: Bool
  , _mAttachments   :: Seq Attachment
  , _mInReplyToMsg  :: ReplyState
  , _mMessageId     :: Maybe MessageId
  , _mReactions     :: Map.Map Text Int
  , _mOriginalPost  :: Maybe Post
  , _mFlagged       :: Bool
  , _mChannelId     :: Maybe ChannelId
  } deriving (Show)

isPostMessage :: Message -> Bool
isPostMessage m =
    isJust (_mMessageId m >>= messageIdPostId)

messagePostId :: Message -> Maybe PostId
messagePostId m = do
    mId <- _mMessageId m
    messageIdPostId mId

isDeletable :: Message -> Bool
isDeletable m =
    isJust (messagePostId m) &&
    case _mType m of
      CP NormalPost -> True
      CP Emote -> True
      _ -> False

isFlaggable :: Message -> Bool
isFlaggable = isJust . messagePostId

isReplyable :: Message -> Bool
isReplyable m =
    isJust (messagePostId m) &&
    case _mType m of
      CP NormalPost -> True
      CP Emote -> True
      _ -> False

isEditable :: Message -> Bool
isEditable m =
    isJust (messagePostId m) &&
    case _mType m of
      CP NormalPost -> True
      CP Emote -> True
      _ -> False

isReplyTo :: PostId -> Message -> Bool
isReplyTo expectedParentId m =
    case _mInReplyToMsg m of
        NotAReply                -> False
        InReplyTo actualParentId -> actualParentId == expectedParentId

isGap :: Message -> Bool
isGap m = case _mType m of
            C UnknownGapBefore -> True
            C UnknownGapAfter -> True
            _ -> False

isTransition :: Message -> Bool
isTransition m = case _mType m of
                   C DateTransition -> True
                   C NewMessagesTransition -> True
                   _ -> False

isEmote :: Message -> Bool
isEmote m = case _mType m of
              CP Emote -> True
              _ -> False

isJoinLeave :: Message -> Bool
isJoinLeave m = case _mType m of
                  CP Join -> True
                  CP Leave -> True
                  _ -> False

-- | A 'Message' is the representation we use for storage and
--   rendering, so it must be able to represent either a
--   post from Mattermost or an internal message. This represents
--   the union of both kinds of post types.
data MessageType = C ClientMessageType
                 | CP ClientPostType
                 deriving (Show)

-- | There may be no user (usually an internal message), a reference
-- to a user (by Id), or the server may have supplied a specific
-- username (often associated with bots).
data UserRef = NoUser | UserI UserId | UserOverride Text
               deriving (Eq, Show, Ord)

-- | The 'ReplyState' of a message represents whether a message
--   is a reply, and if so, to what message
data ReplyState =
    NotAReply
    | InReplyTo PostId
    deriving (Show, Eq)

-- | This type represents links to things in the 'open links' view.
data LinkChoice =
    LinkChoice { _linkTime   :: ServerTime
               , _linkUser   :: UserRef
               , _linkName   :: Text
               , _linkURL    :: Text
               , _linkFileId :: Maybe FileId
               } deriving (Eq, Show)

makeLenses ''LinkChoice

-- | Convert a 'ClientMessage' to a 'Message'.  A 'ClientMessage' is
-- one that was generated by the Matterhorn client and which the
-- server knows nothing about.  For example, an error message
-- associated with passing a link to the local browser.
clientMessageToMessage :: ClientMessage -> Message
clientMessageToMessage cm = Message
  { _mText          = getBlocks (cm^.cmText)
  , _mMarkdownSource = cm^.cmText
  , _mUser          = NoUser
  , _mDate          = cm^.cmDate
  , _mType          = C $ cm^.cmType
  , _mPending       = False
  , _mDeleted       = False
  , _mAttachments   = Seq.empty
  , _mInReplyToMsg  = NotAReply
  , _mMessageId     = Nothing
  , _mReactions     = Map.empty
  , _mOriginalPost  = Nothing
  , _mFlagged       = False
  , _mChannelId     = Nothing
  }


-- | Builds a message from a ClientPost and also returns the set of
-- usernames mentioned in the text of the message.
clientPostToMessage :: ClientPost -> (Message, S.Set Text)
clientPostToMessage cp = (m, usernames)
    where
        usernames = findUsernames $ cp^.cpText
        m = Message { _mText = cp^.cpText
                    , _mMarkdownSource = cp^.cpMarkdownSource
                    , _mUser =
                        case cp^.cpUserOverride of
                            Just n | cp^.cpType == NormalPost -> UserOverride (n <> "[BOT]")
                            _ -> maybe NoUser UserI $ cp^.cpUser
                    , _mDate = cp^.cpDate
                    , _mType = CP $ cp^.cpType
                    , _mPending = cp^.cpPending
                    , _mDeleted = cp^.cpDeleted
                    , _mAttachments = cp^.cpAttachments
                    , _mInReplyToMsg =
                        case cp^.cpInReplyToPost of
                            Nothing  -> NotAReply
                            Just pId -> InReplyTo pId
                    , _mMessageId = Just $ MessagePostId $ cp^.cpPostId
                    , _mReactions = cp^.cpReactions
                    , _mOriginalPost = Just $ cp^.cpOriginalPost
                    , _mFlagged = False
                    , _mChannelId = Just $ cp^.cpChannelId
                    }


newMessageOfType :: Text -> MessageType -> ServerTime -> Message
newMessageOfType text typ d = Message
  { _mText         = getBlocks text
  , _mMarkdownSource = text
  , _mUser         = NoUser
  , _mDate         = d
  , _mType         = typ
  , _mPending      = False
  , _mDeleted      = False
  , _mAttachments  = Seq.empty
  , _mInReplyToMsg = NotAReply
  , _mMessageId    = Nothing
  , _mReactions    = Map.empty
  , _mOriginalPost = Nothing
  , _mFlagged      = False
  , _mChannelId    = Nothing
  }

-- ** 'Message' Lenses

makeLenses ''Message

-- ----------------------------------------------------------------------

-- * Message Collections

-- | A wrapper for an ordered, unique list of 'Message' values.
--
-- This type has (and promises) the following instances: Show,
-- Functor, Monoid, Foldable, Traversable
type ChronologicalMessages = DirectionalSeq Chronological Message
type Messages = ChronologicalMessages

-- | There are also cases where the list of 'Message' values are kept
-- in reverse order (most recent -> oldest); these cases are
-- represented by the `RetrogradeMessages` type.
type RetrogradeMessages = DirectionalSeq Retrograde Message

-- ** Common operations on Messages

filterMessages ::
  SeqDirection seq =>
  (Message -> Bool) ->
  DirectionalSeq seq Message ->
  DirectionalSeq seq Message
filterMessages p = onDirectedSeq (Seq.filter p)

class MessageOps a where
    -- | addMessage inserts a date in proper chronological order, with
    -- the following extra functionality:
    --     * no duplication (by PostId)
    --     * no duplication (adjacent UnknownGap entries)
    addMessage :: Message -> a -> a

instance MessageOps ChronologicalMessages where
    addMessage m ml =
        case viewr (dseq ml) of
            EmptyR -> DSeq $ singleton m
            _ :> l ->
                case compare (m^.mDate) (l^.mDate) of
                  GT -> DSeq $ dseq ml |> m
                  EQ -> if m^.mMessageId == l^.mMessageId && isJust (m^.mMessageId)
                        then ml
                        else dirDateInsert m ml
                  LT -> dirDateInsert m ml

dirDateInsert :: Message -> ChronologicalMessages -> ChronologicalMessages
dirDateInsert m = onDirectedSeq $ finalize . foldr insAfter initial
   where initial = (Just m, mempty)
         insAfter c (Nothing, l) = (Nothing, c <| l)
         insAfter c (Just n, l) =
             case compare (n^.mDate) (c^.mDate) of
               GT -> (Nothing, c <| (n <| l))
               EQ -> if n^.mMessageId == c^.mMessageId && isJust (c^.mMessageId)
                     then (Nothing, c <| l)
                     else (Just n, c <| l)
               LT -> (Just n, c <| l)
         finalize (Just n, l) = n <| l
         finalize (_, l) = l

noMessages :: Messages
noMessages = DSeq mempty

-- | Reverse the order of the messages
reverseMessages :: Messages -> RetrogradeMessages
reverseMessages = DSeq . Seq.reverse . dseq

-- | Unreverse the order of the messages
unreverseMessages :: RetrogradeMessages -> Messages
unreverseMessages = DSeq . Seq.reverse . dseq

splitDirSeqOn :: SeqDirection d
              => (a -> Bool)
              -> DirectionalSeq d a
              -> (Maybe a, (DirectionalSeq (ReverseDirection d) a,
                            DirectionalSeq d a))
splitDirSeqOn f msgs =
    let (removed, remaining) = dirSeqBreakl f msgs
        devomer = DSeq $ Seq.reverse $ dseq removed
    in (withDirSeqHead id remaining, (devomer, onDirectedSeq (Seq.drop 1) remaining))

-- ----------------------------------------------------------------------
-- * Operations on Posted Messages

-- | Searches for the specified MessageId and returns a tuple where the
-- first element is the Message associated with the MessageId (if it
-- exists), and the second element is another tuple: the first element
-- of the second is all the messages from the beginning of the list to
-- the message just before the MessageId message (or all messages if not
-- found) *in reverse order*, and the second element of the second are
-- all the messages that follow the found message (none if the message
-- was never found) in *forward* order.
splitMessages :: Maybe MessageId
              -> DirectionalSeq Chronological (Message, ThreadState)
              -> (Maybe (Message, ThreadState), (DirectionalSeq Retrograde (Message, ThreadState), DirectionalSeq Chronological (Message, ThreadState)))
splitMessages mid msgs = splitDirSeqOn (\(m, _) -> isJust mid && m^.mMessageId == mid) msgs

-- | findMessage searches for a specific message as identified by the
-- PostId.  The search starts from the most recent messages because
-- that is the most likely place the message will occur.
findMessage :: MessageId -> Messages -> Maybe Message
findMessage mid msgs =
    findIndexR (\m -> m^.mMessageId == Just mid) (dseq msgs)
    >>= Just . Seq.index (dseq msgs)

-- | Look forward for the first Message with an ID that follows the
-- specified Id and return it.  If no input Id supplied, get the
-- latest (most recent chronologically) Message in the input set.
getNextMessage :: Maybe MessageId -> Messages -> Maybe Message
getNextMessage = getRelMessageId

-- | Look backward for the first Message with an ID that follows the
-- specified MessageId and return it.  If no input MessageId supplied,
-- get the latest (most recent chronologically) Message in the input
-- set.
getPrevMessage :: Maybe MessageId -> Messages -> Maybe Message
getPrevMessage mId = getRelMessageId mId . reverseMessages

-- | Look forward for the first Message with an ID that follows the
-- specified MessageId and return that found Message's ID; if no input
-- MessageId is specified, return the latest (most recent
-- chronologically) MessageId (if any) in the input set.
getNextMessageId :: Maybe MessageId -> Messages -> Maybe MessageId
getNextMessageId mId = _mMessageId <=< getNextMessage mId

-- | Look backwards for the first Message with an ID that comes before
-- the specified MessageId and return that found Message's ID; if no
-- input MessageId is specified, return the latest (most recent
-- chronologically) MessageId (if any) in the input set.
getPrevMessageId :: Maybe MessageId -> Messages -> Maybe MessageId
getPrevMessageId mId = _mMessageId <=< getPrevMessage mId

-- | Look forward for the first Message with an ID that follows the
-- specified PostId and return that found Message's PostID; if no
-- input PostId is specified, return the latest (most recent
-- chronologically) PostId (if any) in the input set.
getNextPostId :: Maybe PostId -> Messages -> Maybe PostId
getNextPostId pid = messagePostId <=< getNextMessage (MessagePostId <$> pid)

-- | Look backwards for the first Post with an ID that comes before
-- the specified PostId.
getPrevPostId :: Maybe PostId -> Messages -> Maybe PostId
getPrevPostId pid = messagePostId <=< getPrevMessage (MessagePostId <$> pid)


getRelMessageId :: SeqDirection dir =>
                   Maybe MessageId
                -> DirectionalSeq dir Message
                -> Maybe Message
getRelMessageId mId =
  let isMId = const ((==) mId . _mMessageId) <$> mId
  in getRelMessage isMId

-- | Internal worker function to return a different user message in
-- relation to either the latest point or a specific message.
getRelMessage :: SeqDirection dir =>
                 Maybe (Message -> Bool)
              -> DirectionalSeq dir Message
              -> Maybe Message
getRelMessage matcher msgs =
  let after = case matcher of
                Just matchFun -> case splitDirSeqOn matchFun msgs of
                                   (_, (_, ms)) -> ms
                Nothing -> msgs
  in withDirSeqHead id $ filterMessages validSelectableMessage after

-- | Find the most recent message that is a Post (as opposed to a
-- local message) (if any).
getLatestPostMsg :: Messages -> Maybe Message
getLatestPostMsg msgs =
    case viewr $ dropWhileR (not . validUserMessage) (dseq msgs) of
      EmptyR -> Nothing
      _ :> m -> Just m

-- | Find the oldest message that is a message with an ID.
getEarliestSelectableMessage :: Messages -> Maybe Message
getEarliestSelectableMessage msgs =
    case viewl $ dropWhileL (not . validSelectableMessage) (dseq msgs) of
      EmptyL -> Nothing
      m :< _ -> Just m

-- | Find the most recent message that is a message with an ID.
getLatestSelectableMessage :: Messages -> Maybe Message
getLatestSelectableMessage msgs =
    case viewr $ dropWhileR (not . validSelectableMessage) (dseq msgs) of
      EmptyR -> Nothing
      _ :> m -> Just m

-- | Find the earliest message that is a Post (as opposed to a
-- local message) (if any).
getEarliestPostMsg :: Messages -> Maybe Message
getEarliestPostMsg msgs =
    case viewl $ dropWhileL (not . validUserMessage) (dseq msgs) of
      EmptyL -> Nothing
      m :< _ -> Just m

-- | Find the most recent message that is a message posted by a user
-- that matches the test (if any), skipping local client messages and
-- any user event that is not a message (i.e. find a normal message or
-- an emote).
findLatestUserMessage :: (Message -> Bool) -> Messages -> Maybe Message
findLatestUserMessage f ml =
    case viewr $ dropWhileR (\m -> not (validUserMessage m && f m)) $ dseq ml of
      EmptyR -> Nothing
      _ :> m -> Just m

validUserMessage :: Message -> Bool
validUserMessage m =
    not (m^.mDeleted) && case m^.mMessageId of
        Just (MessagePostId _) -> True
        _ -> False

validSelectableMessage :: Message -> Bool
validSelectableMessage m = (not $ m^.mDeleted) && (isJust $ m^.mMessageId)

-- ----------------------------------------------------------------------
-- * Operations on any Message type

-- | Return all messages that were posted after the specified date/time.
messagesAfter :: ServerTime -> Messages -> Messages
messagesAfter viewTime = onDirectedSeq $ takeWhileR (\m -> m^.mDate > viewTime)

-- | Removes any Messages (all types) for which the predicate is true
-- from the specified subset of messages (identified by a starting and
-- ending MessageId, inclusive) and returns the resulting list (from
-- start to finish, irrespective of 'firstId' and 'lastId') and the
-- list of removed items.
--
--    start       | end          |  operates-on              | (test) case
--   --------------------------------------------------------|-------------
--   Nothing      | Nothing      | entire list               |  C1
--   Nothing      | Just found   | start --> found]          |  C2
--   Nothing      | Just missing | nothing [suggest invalid] |  C3
--   Just found   | Nothing      | [found --> end            |  C4
--   Just found   | Just found   | [found --> found]         |  C5
--   Just found   | Just missing | [found --> end            |  C6
--   Just missing | Nothing      | nothing [suggest invalid] |  C7
--   Just missing | Just found   | start --> found]          |  C8
--   Just missing | Just missing | nothing [suggest invalid] |  C9
--
--  @removeMatchesFromSubset matchPred fromId toId msgs = (remaining, removed)@
--
removeMatchesFromSubset :: (Message -> Bool) -> Maybe MessageId -> Maybe MessageId
                        -> Messages -> (Messages, Messages)
removeMatchesFromSubset matching firstId lastId msgs =
    let knownIds = fmap (^.mMessageId) msgs
    in if isNothing firstId && isNothing lastId
       then swap $ dirSeqPartition matching msgs
       else if isJust firstId && firstId `elem` knownIds
            then onDirSeqSubset
                (\m -> m^.mMessageId == firstId)
                (if isJust lastId then \m -> m^.mMessageId == lastId else const False)
                (swap . dirSeqPartition matching) msgs
            else if isJust lastId && lastId `elem` knownIds
                 then onDirSeqSubset
                     (const True)
                     (\m -> m^.mMessageId == lastId)
                     (swap . dirSeqPartition matching) msgs
                 else (msgs, noMessages)

-- | Performs an operation on the first Message, returning just the
-- result of that operation, or Nothing if there were no messages.
-- Note that the message is not necessarily a posted user message.
withFirstMessage :: SeqDirection dir => (Message -> r) -> DirectionalSeq dir Message -> Maybe r
withFirstMessage = withDirSeqHead

msgURLs :: Message -> Seq LinkChoice
msgURLs msg
  | NoUser <- msg^.mUser = mempty
  | otherwise =
  let uid = msg^.mUser
      msgUrls = (\ (url, text) -> LinkChoice (msg^.mDate) uid text url Nothing) <$>
                  (mconcat $ blockGetURLs <$> (toList $ msg^.mText))
      attachmentURLs = (\ a ->
                          LinkChoice
                            (msg^.mDate)
                            uid
                            ("attachment `" <> (a^.attachmentName) <> "`")
                            (a^.attachmentURL)
                            (Just (a^.attachmentFileId)))
                       <$> (msg^.mAttachments)
  in msgUrls <> attachmentURLs

blockGetURLs :: C.Block -> Seq.Seq (Text, Text)
blockGetURLs (C.Para is) = mconcat $ inlineGetURLs <$> toList is
blockGetURLs (C.Header _ is) = mconcat $ inlineGetURLs <$> toList is
blockGetURLs (C.Blockquote bs) = mconcat $ blockGetURLs <$> toList bs
blockGetURLs (C.List _ _ bss) = mconcat $ mconcat $ (blockGetURLs <$>) <$> (toList <$> bss)
blockGetURLs _ = mempty

inlineGetURLs :: C.Inline -> Seq.Seq (Text, Text)
inlineGetURLs (C.Emph is) = mconcat $ inlineGetURLs <$> toList is
inlineGetURLs (C.Strong is) = mconcat $ inlineGetURLs <$> toList is
inlineGetURLs (C.Link is url "") = (url, inlinesText is) Seq.<| (mconcat $ inlineGetURLs <$> toList is)
inlineGetURLs (C.Link is _ url) = (url, inlinesText is) Seq.<| (mconcat $ inlineGetURLs <$> toList is)
inlineGetURLs (C.Image is url _) = Seq.singleton (url, inlinesText is)
inlineGetURLs _ = mempty

inlinesText :: Seq C.Inline -> Text
inlinesText = F.fold . fmap go
  where go (C.Str t)       = t
        go C.Space         = " "
        go C.SoftBreak     = " "
        go C.LineBreak     = " "
        go (C.Emph is)     = F.fold (fmap go is)
        go (C.Strong is)   = F.fold (fmap go is)
        go (C.Code t)      = t
        go (C.Link is _ _) = F.fold (fmap go is)
        go (C.Image is _ _) = "[image" <> altInlinesString is <> "]"
        go (C.Entity t)    = t
        go (C.RawHtml t)   = t

altInlinesString :: Seq C.Inline -> Text
altInlinesString is | Seq.null is = ""
                    | otherwise = ":" <> inlinesText is
