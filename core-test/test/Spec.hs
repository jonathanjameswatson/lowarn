import Spec.ManualDsu (manualDsuTests)
import Spec.Story (storyTests)
import Spec.VersionNumber (versionNumberTests)
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain $
    testGroup
      "Lowarn tests"
      [ manualDsuTests,
        storyTests,
        versionNumberTests
      ]
