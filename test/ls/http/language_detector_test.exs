defmodule LS.HTTP.LanguageDetectorTest do
  use ExUnit.Case, async: true
  alias LS.HTTP.LanguageDetector, as: L

  defp lang(body), do: L.detect(body, [], "", "")

  test "rejects template/placeholder/invalid lang values (root cause of %paraglide.lang%)" do
    assert lang(~s(<html lang="%paraglide.lang%">hi</html>)) == ""
    assert lang(~s(<html lang="{{ locale }}">hi</html>)) == ""
    assert lang(~s(<html lang="[[lang]]">hi</html>)) == ""
    assert lang(~s(<html lang="x-default">hi</html>)) == ""
    assert lang(~s(<html lang="zxx">hi</html>)) == ""
    assert lang(~s(<html lang="und">hi</html>)) == ""
  end

  test "accepts and normalizes real language codes to ISO 639-1" do
    assert lang(~s(<html lang="en-US">hi</html>)) == "en"
    assert lang(~s(<html lang="fr">hi</html>)) == "fr"
    assert lang(~s(<html lang="PT-BR">hi</html>)) == "pt"
    assert lang(~s(<html lang="de_DE">hi</html>)) == "de"
  end

  test "no usable signal yields empty string" do
    assert lang("<html><body>hi</body></html>") == ""
    assert L.detect(nil, [], "", "") == ""
  end
end
