{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}

module Main (main) where

import           BuildInfo_ambiata_box

import           Box hiding ((</>))

import           Control.Monad.IO.Class
import           Control.Monad.Trans.Either

import           Data.List (sort)
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T

import           Options.Applicative

import           P

import           System.Directory
import           System.Environment
import           System.Exit
import           System.FilePath ((</>))
import           System.IO
import           System.Posix.Process
import           System.Posix.User

import           Text.PrettyPrint.Boxes ((<+>))
import qualified Text.PrettyPrint.Boxes as PB

import           X.Control.Monad.Trans.Either
import           X.Options.Applicative

------------------------------------------------------------------------
-- Types

data BoxCommand =
    BoxIP    Query HostType
  | BoxSSH   GatewayType Query [SSHArg]
  | BoxRSH   GatewayType Query [SSHArg]
  | BoxRSync GatewayType Query [SSHArg]
  | BoxList  Query
  deriving (Eq, Show)

data HostType =
    ExternalHost
  | InternalHost
  deriving (Eq, Show)

type SSHArg = Text

data BoxCommandError =
    BoxError    BoxError
  | BoxAwsError Error
  | BoxNoFilter
  | BoxNoMatches
  | BoxNoGateway
  | BoxMissingRSHHost
  | BoxInvalidRSHHost Text

data ANSIEscapes =
    EnableANSIEscapes
  | DisableANSIEscapes

------------------------------------------------------------------------
-- Main

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  dispatch boxP >>= \case

    ZshCommands cmds -> do
      forM_ cmds $ \(Command label desc _) ->
        T.putStrLn (label <> ":" <> desc)

    Safe VersionCommand -> do
      prog <- getProgName
      putStrLn (prog <> ": " <> buildInfoVersion)
      exitSuccess

    Safe (RunCommand r cmd) -> do
      case cmd of
        BoxIP     q host   -> runCommand (boxIP  r q host)
        BoxSSH    g q args -> runCommand (boxSSH r g q args)
        BoxRSH    g q args -> runCommand (boxRSH r g q args)
        BoxRSync  g q args -> runCommand (const $ boxRSync r g q args)
        BoxList   q        -> runCommand (boxList q)

runCommand :: ([Box] -> EitherT BoxCommandError IO ()) -> IO ()
runCommand cmd = orDie boxCommandErrorRender $ do
  boxes <- fetchBoxes
  cmd boxes
  liftIO exitSuccess


------------------------------------------------------------------------
-- Commands

boxIP :: RunType -> Query -> HostType -> [Box] -> EitherT BoxCommandError IO ()
boxIP _ q hostType boxes = do
  b <- randomBoxOfQuery q boxes
  liftIO (putStrLn . T.unpack . unHost . selectHost hostType $ b)

boxSSH :: RunType -> GatewayType -> Query -> [SSHArg] -> [Box] -> EitherT BoxCommandError IO ()
boxSSH runType gwType qTarget args boxes = do
  let qGateway = Query ExactAll (Exact $ gatewayFlavour gwType) InfixAll ExactAll

  target  <- randomBoxOfQuery qTarget  boxes
  gateway <- firstEitherT (\case
                             BoxNoMatches -> BoxNoGateway
                             e            -> e) $ randomBoxOfQuery qGateway boxes

  let boxNiceName b = unName (boxName b) <> "." <> unInstanceId (boxInstance b)
      boxAlias    b = "box." <> boxNiceName b <> ".jump"

  let targetHost  = unHost (selectHost InternalHost target)
      gatewayHost = unHost (selectHost ExternalHost gateway)

  user     <- liftIO userEnv
  identity <- liftIO identityEnv

  let args' = [ -- ProxyCommand bounces us off the gateway. Note that we pipe
                -- netcat's stderr to /dev/null to avoid the annoying 'Killed
                -- by signal 1.' message when the session finishes.
                "-o", "ProxyCommand=ssh" <> " -i " <> identity
                                         <> " -o HostKeyAlias=" <> boxAlias gateway
                                         <> " " <> user <> "@" <> gatewayHost
                                         <> " nc %h %p 2>/dev/null"

                -- Keep track of host keys using the target's somewhat unique
                -- name.
              , "-o", "HostKeyAlias=" <> boxAlias target

                -- Connect to target box.
              , user <> "@" <> targetHost

                -- Pass on any additional arguments to 'ssh'.
              ] <> args

  case runType of
    DryRun  ->
      liftIO (print ("ssh" : args'))

    RealRun -> do
      -- Set the title of the terminal.
      ansi <- liftIO ansiEscapesEnv
      case ansi of
        DisableANSIEscapes -> return ()
        EnableANSIEscapes  -> liftIO $ do
          T.putStr ("\ESC]0;" <> boxNiceName target <> "\BEL")
          hFlush stdout

      -- This call never returns, the current process is replaced by 'ssh'.
      liftIO (exec "ssh" args')

boxRSH :: RunType -> GatewayType -> Query -> [SSHArg] -> [Box] -> EitherT BoxCommandError IO ()
boxRSH runType gwType qTarget args boxes = do
  case args of
    [] ->
      left BoxMissingRSHHost
    ("":xs) ->
      boxSSH runType gwType qTarget xs boxes
    (h:_) ->
      left $ BoxInvalidRSHHost h

boxRSync :: RunType -> GatewayType -> Query -> [SSHArg] -> EitherT BoxCommandError IO ()
boxRSync runType gwType qTarget args = do
  box <- liftIO getExecutablePath
  let secure = if gwType == GatewaySecure then "--secure" else ""
  let args' = [ "--rsh", T.intercalate " " [T.pack box, "rsh", secure, queryRender qTarget, "--"]] <> args
  case runType of
    DryRun  ->
      liftIO (print ("rsync" : args'))
    RealRun -> do
      liftIO (exec "rsync" args')

boxList :: Query -> [Box] -> EitherT BoxCommandError IO ()
boxList q boxes = liftIO $ do
    putStrLn ("total " <> show (length sorted))

    PB.printBox $ col PB.left  (unClient     . boxClient)
              <+> col PB.left  (unFlavour    . boxFlavour)
             <++> col PB.right (unName       . boxShortName)
             <++> col PB.left  (unHost       . boxHost)
             <++> col PB.left  (unHost       . boxPublicHost)
             <++> col PB.left  (unInstanceId . boxInstance)
  where
    sorted       = sort (query q boxes)
    col align f  = PB.vcat align (fmap (PB.text . T.unpack . f) sorted)

    (<++>) l r = l PB.<> PB.emptyBox 0 2 PB.<> r


------------------------------------------------------------------------
-- Utils

cachedBoxes :: EitherT BoxCommandError IO [Box]
cachedBoxes = do
  let timeout = 60 -- seconds
  path  <- liftIO cacheEnv
  cache <- liftIO (readCache path timeout)
  case cache of
    Just boxes -> return boxes
    Nothing    -> fetchBoxes

fetchBoxes :: EitherT BoxCommandError IO [Box]
fetchBoxes = do
    -- We don't want people setting a default AWS region
    -- on their local machine, use Sydney instead.
    mregion <- getRegionFromEnv
    env     <- newEnv (fromMaybe Sydney mregion) Discover
    store   <- liftIO storeEnv
    boxes   <- squash (runAWST env (readBoxes store))
    path    <- liftIO cacheEnv
    liftIO (writeCache path boxes)
    return boxes
  where
    squash x = bimapEitherT BoxError    id . hoistEither
           =<< bimapEitherT BoxAwsError id x

randomBoxOfQuery :: MonadIO m => Query -> [Box] -> EitherT BoxCommandError m Box
randomBoxOfQuery q bs = do
  unless (queryHasMatch q) (left BoxNoFilter)
  maybe (left BoxNoMatches) return =<< liftIO (selectRandomBox (query q bs))

selectHost :: HostType -> Box -> Host
selectHost InternalHost = boxHost
selectHost ExternalHost = boxPublicHost

boxCommandErrorRender :: BoxCommandError -> Text
boxCommandErrorRender (BoxError e)          = boxErrorRender e
boxCommandErrorRender (BoxAwsError e)       = errorRender e
boxCommandErrorRender (BoxNoFilter)         = "No filter specified"
boxCommandErrorRender (BoxNoMatches)        = "No matching boxes found"
boxCommandErrorRender (BoxNoGateway)        = "No usable gateways found"
boxCommandErrorRender (BoxMissingRSHHost)   = "Expected rsync to pass an argument for the hostname"
boxCommandErrorRender (BoxInvalidRSHHost _) = "Expected an empty host to be specified, i.e. box rsync <query> -- -aH local-file :remote-file."

exec :: Text -> [Text] -> IO a
exec cmd args = executeFile (T.unpack cmd) True (fmap T.unpack args) Nothing


------------------------------------------------------------------------
-- Environment Variables

storeEnv :: IO BoxStore
storeEnv =
    fmap (maybe (BoxStoreS3 boxStoreAddress) (\s -> maybe (BoxStoreLocal s) BoxStoreS3 . addressFromText $ T.pack s))
  $ lookupEnv "BOX_STORE"

userEnv :: IO Text
userEnv =
  T.pack <$> (maybe getEffectiveUserName return =<< lookupEnv "BOX_USER")

identityEnv :: IO Text
identityEnv = do
  home <- getHomeDirectory
  T.pack . fromMaybe (home </> ".ssh/ambiata_rsa") <$> lookupEnv "BOX_IDENTITY"

cacheEnv :: IO FilePath
cacheEnv = do
  home <- getHomeDirectory
  fromMaybe (home </> ".ambiata/box/cache") <$> lookupEnv "BOX_CACHE"

ansiEscapesEnv :: IO ANSIEscapes
ansiEscapesEnv = do
  tty <- liftIO (hIsTerminalDevice stdout)
  ok  <- (/= "0") . fromMaybe "1" <$> lookupEnv "BOX_ANSI_ESCAPES"
  return (if tty && ok then EnableANSIEscapes
                       else DisableANSIEscapes)


------------------------------------------------------------------------
-- Argument Parsing

boxP :: Parser (CompCommands BoxCommand)
boxP = commandsP boxCommands

boxCommands :: [Command BoxCommand]
boxCommands =
  [ Command "ip"  "Get the IP address of a box."
            (BoxIP    <$> queryP <*> hostTypeP)

  , Command "ssh" "SSH to a box."
            (BoxSSH   <$> gatewayP <*> queryP <*> many sshArgP)

  , Command "rsh" "SSH to a box with a shell interface compatible with rsync."
            (BoxRSH   <$> gatewayP <*> queryP <*> many sshArgP )

  , Command "rsync" "SSH to a box."
            (BoxRSync <$> gatewayP <*> queryP <*> many sshArgP)

  , Command "ls"  "List available boxes."
            (BoxList  <$> (queryP <|> pure matchAll))

  ]

hostTypeP :: Parser HostType
hostTypeP =
  flag InternalHost ExternalHost $
       long "external"
    <> help "Display the external ip address rather than the internal one (which is the default)."

gatewayP :: Parser GatewayType
gatewayP =
  flag Gateway GatewaySecure $
       long "secure"
    <> short 's'
    <> help "Use a 2FA-enabled gateway."

queryP :: Parser Query
queryP =
  argument (pOption queryParser) $
       metavar "FILTER"
    <> completer filterCompleter
    <> help "Filter using the following syntax: CLIENT[:FLAVOUR[:NAME]]"

matchAll :: Query
matchAll = Query ExactAll ExactAll InfixAll ExactAll

sshArgP :: Parser SSHArg
sshArgP =
  argument textRead $
       metavar "SSH_ARGUMENTS"
    <> help "Extra arguments to pass to ssh."

filterCompleter :: Completer
filterCompleter = mkCompleter $ \arg -> do
    boxes <- tryFetchBoxes
    return . fmap T.unpack
           $ completions (T.pack arg) boxes
  where
    tryFetchBoxes :: IO [Box]
    tryFetchBoxes = either (const []) id <$> runEitherT cachedBoxes


------------------------------------------------------------------------
-- Command Arguments
--   This can be moved to X.Options.Applicative once we get it right.

data Command a = Command {
    _cmdLabel       :: Text
  , _cmdDescription :: Text
  , _cmdParser      :: Parser a
  }

data CompCommands a =
    ZshCommands [Command a]
  | Safe (SafeCommand a)

commandsP :: [Command a] -> Parser (CompCommands a)
commandsP commands =
      ZshCommands commands <$ commandsFlag
  <|> Safe <$> safeCommand cmdP
  where
    cmdP = subparser
         . mconcat
         . fmap fromCommand
         $ commands

commandsFlag :: Parser ()
commandsFlag = flag' () (long "zsh-commands" <> hidden)

fromCommand :: Command a -> Mod CommandFields a
fromCommand (Command label description parser) =
  command' (T.unpack label) (T.unpack description) parser
