-- Which platforms the 6.7M businesses actually run on (tech fingerprint).
SELECT multiIf(
  positionCaseInsensitive(concat(http_tech, http_apps), 'shopify') > 0, 'Shopify',
  positionCaseInsensitive(concat(http_tech, http_apps), 'woocommerce') > 0, 'WooCommerce',
  positionCaseInsensitive(concat(http_tech, http_apps), 'bigcommerce') > 0, 'BigCommerce',
  positionCaseInsensitive(concat(http_tech, http_apps), 'magento') > 0, 'Magento',
  positionCaseInsensitive(concat(http_tech, http_apps), 'squarespace') > 0, 'Squarespace',
  positionCaseInsensitive(concat(http_tech, http_apps), 'webflow') > 0, 'Webflow',
  positionCaseInsensitive(concat(http_tech, http_apps), 'wix') > 0, 'Wix',
  positionCaseInsensitive(concat(http_tech, http_apps), 'wordpress') > 0, 'WordPress',
  positionCaseInsensitive(concat(http_tech, http_apps), 'godaddy') > 0, 'GoDaddy',
  positionCaseInsensitive(concat(http_tech, http_apps), 'joomla') > 0, 'Joomla',
  positionCaseInsensitive(concat(http_tech, http_apps), 'drupal') > 0, 'Drupal',
  positionCaseInsensitive(concat(http_tech, http_apps), 'typo3') > 0, 'TYPO3',
  positionCaseInsensitive(concat(http_tech, http_apps), 'hubspot') > 0, 'HubSpot CMS',
  positionCaseInsensitive(concat(http_tech, http_apps), 'ghost') > 0, 'Ghost',
  positionCaseInsensitive(concat(http_tech, http_apps), 'weebly') > 0, 'Weebly',
  positionCaseInsensitive(concat(http_tech, http_apps), 'prestashop') > 0, 'PrestaShop',
  http_tech != '', 'other/custom', '(no tech data)') AS platform,
  count() AS businesses
FROM ls.businesses
GROUP BY platform ORDER BY businesses DESC LIMIT 20
SETTINGS max_threads = 2, max_bytes_before_external_group_by = 1000000000
