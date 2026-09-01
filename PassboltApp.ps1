param(
    [switch]$SelfTest,
    [string]$RenderPreviewPath = "",
    [ValidateSet("Configuration", "Inventory", "Review", "Import")]
    [string]$RenderPreviewPage = "Configuration",
    [ValidateSet("new_import", "recovery", "existing_acl")]
    [string]$RenderPreviewImportTab = "new_import",
    [ValidateSet("initial", "populated")]
    [string]$RenderPreviewImportState = "initial",
    [ValidateRange(1160, 3840)]
    [int]$RenderPreviewWidth = 1360,
    [ValidateRange(740, 2160)]
    [int]$RenderPreviewHeight = 860,
    [ValidateSet(96, 120, 144, 192)]
    [int]$RenderPreviewDpi = 96
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Security

$ProjectRoot = $PSScriptRoot
$ProbeScript = Join-Path $ProjectRoot "passbolt_api_probe.py"
$InventoryScript = Join-Path $ProjectRoot "passbolt_app.py"
$ReviewScript = Join-Path $ProjectRoot "passbolt_review.py"
$ImportScript = Join-Path $ProjectRoot "passbolt_import.py"
$CryptoScript = Join-Path $ProjectRoot "passbolt_crypto.mjs"
$IntegrationMatrixScript = Join-Path $ProjectRoot "passbolt_integration_matrix.py"
$LocalProjectScript = Join-Path $ProjectRoot "passbolt_project.py"
$ReceiptScript = Join-Path $ProjectRoot "passbolt_receipt.py"
$BundledPython = Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
$BundledNode = Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe"
$ConfiguredPython = [Environment]::GetEnvironmentVariable("PASSBOLT_APP_PYTHON")
$ConfiguredNode = [Environment]::GetEnvironmentVariable("PASSBOLT_APP_NODE")

if (-not [string]::IsNullOrWhiteSpace($ConfiguredPython)) {
    $ConfiguredPython = [IO.Path]::GetFullPath($ConfiguredPython)
    if (-not (Test-Path -LiteralPath $ConfiguredPython -PathType Leaf)) {
        throw "L'eseguibile Python configurato non esiste: $ConfiguredPython"
    }
    $PythonExecutable = $ConfiguredPython
} elseif (Test-Path -LiteralPath $BundledPython -PathType Leaf) {
    $PythonExecutable = $BundledPython
} elseif (Get-Command python -ErrorAction SilentlyContinue) {
    $PythonExecutable = (Get-Command python).Source
} elseif (Get-Command py -ErrorAction SilentlyContinue) {
    $PythonExecutable = (Get-Command py).Source
} else {
    throw "Python non trovato. Installare Python 3.11 o superiore."
}

if (-not [string]::IsNullOrWhiteSpace($ConfiguredNode)) {
    $ConfiguredNode = [IO.Path]::GetFullPath($ConfiguredNode)
    if (-not (Test-Path -LiteralPath $ConfiguredNode -PathType Leaf)) {
        throw "L'eseguibile Node.js configurato non esiste: $ConfiguredNode"
    }
    $NodeExecutable = $ConfiguredNode
} elseif (Test-Path -LiteralPath $BundledNode -PathType Leaf) {
    $NodeExecutable = $BundledNode
} elseif (Get-Command node -ErrorAction SilentlyContinue) {
    $NodeExecutable = (Get-Command node).Source
} else {
    throw "Node.js non trovato. Installare Node.js 18 o superiore."
}

[xml]$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Passbolt Migration Assistant - v0.29.0-beta.1"
        Width="1360" Height="860" MinWidth="1160" MinHeight="740"
        WindowStartupLocation="CenterScreen" Background="#F5F5F7"
        FontFamily="Segoe UI Variable Text, Segoe UI"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display" TextOptions.TextRenderingMode="ClearType">
    <Window.Resources>
        <SolidColorBrush x:Key="TextBrush" Color="#1D1D1F" />
        <SolidColorBrush x:Key="MutedBrush" Color="#6E6E73" />
        <SolidColorBrush x:Key="AccentBrush" Color="#007AFF" />
        <SolidColorBrush x:Key="SurfaceBrush" Color="#FFFFFF" />
        <SolidColorBrush x:Key="CanvasBrush" Color="#F5F5F7" />
        <SolidColorBrush x:Key="SeparatorBrush" Color="#E5E5EA" />
        <SolidColorBrush x:Key="SoftAccentBrush" Color="#EAF3FF" />
        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}" />
        </Style>
        <Style x:Key="PageTitle" TargetType="TextBlock">
            <Setter Property="FontFamily" Value="Segoe UI Variable Display, Segoe UI" />
            <Setter Property="FontSize" Value="30" />
            <Setter Property="FontWeight" Value="SemiBold" />
            <Setter Property="Foreground" Value="{StaticResource TextBrush}" />
        </Style>
        <Style x:Key="PageSubtitle" TargetType="TextBlock">
            <Setter Property="FontSize" Value="13" />
            <Setter Property="Foreground" Value="{StaticResource MutedBrush}" />
            <Setter Property="Margin" Value="0,5,0,0" />
        </Style>
        <Style x:Key="SectionTitle" TargetType="TextBlock">
            <Setter Property="FontSize" Value="17" />
            <Setter Property="FontWeight" Value="SemiBold" />
            <Setter Property="Foreground" Value="{StaticResource TextBrush}" />
        </Style>
        <Style x:Key="StatusPill" TargetType="Border">
            <Setter Property="Background" Value="#EAF8F0" />
            <Setter Property="CornerRadius" Value="12" />
            <Setter Property="Padding" Value="13,7" />
            <Setter Property="VerticalAlignment" Value="Center" />
        </Style>
        <Style x:Key="InfoBanner" TargetType="Border">
            <Setter Property="Background" Value="#EEF6FF" />
            <Setter Property="BorderBrush" Value="#C7DEFA" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="CornerRadius" Value="12" />
            <Setter Property="Padding" Value="14,11" />
        </Style>
        <Style x:Key="WarningBanner" TargetType="Border">
            <Setter Property="Background" Value="#FFF8E1" />
            <Setter Property="BorderBrush" Value="#F2C94C" />
            <Setter Property="BorderThickness" Value="0,1,0,0" />
            <Setter Property="Padding" Value="14,10" />
        </Style>
        <Style x:Key="PrimaryButton" TargetType="Button">
            <Setter Property="Background" Value="#007AFF" />
            <Setter Property="Foreground" Value="White" />
            <Setter Property="FontWeight" Value="SemiBold" />
            <Setter Property="FontSize" Value="13" />
            <Setter Property="MinHeight" Value="40" />
            <Setter Property="Padding" Value="18,9" />
            <Setter Property="BorderBrush" Value="#007AFF" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="Cursor" Value="Hand" />
            <Setter Property="FocusVisualStyle" Value="{x:Null}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="ButtonChrome" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="10" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="ButtonChrome" Property="BorderBrush" Value="#003F7D" /><Setter TargetName="ButtonChrome" Property="BorderThickness" Value="3" /></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#1687FF" /><Setter Property="BorderBrush" Value="#1687FF" /></Trigger>
                <Trigger Property="IsPressed" Value="True"><Setter Property="Background" Value="#0066D6" /><Setter Property="BorderBrush" Value="#0066D6" /></Trigger>
                <Trigger Property="IsEnabled" Value="False"><Setter Property="Background" Value="#D1D1D6" /><Setter Property="BorderBrush" Value="#D1D1D6" /><Setter Property="Foreground" Value="#8E8E93" /></Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="SecondaryButton" TargetType="Button" BasedOn="{StaticResource PrimaryButton}">
            <Setter Property="Background" Value="#FFFFFF" />
            <Setter Property="BorderBrush" Value="#D1D1D6" />
            <Setter Property="Foreground" Value="#1D1D1F" />
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#F2F2F7" /><Setter Property="BorderBrush" Value="#C7C7CC" /></Trigger>
                <Trigger Property="IsPressed" Value="True"><Setter Property="Background" Value="#E5E5EA" /><Setter Property="BorderBrush" Value="#AEAEB2" /></Trigger>
                <Trigger Property="IsEnabled" Value="False"><Setter Property="Background" Value="#F5F5F7" /><Setter Property="BorderBrush" Value="#E5E5EA" /><Setter Property="Foreground" Value="#AEAEB2" /></Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="Button" BasedOn="{StaticResource SecondaryButton}" />
        <Style x:Key="Card" TargetType="Border">
            <Setter Property="Background" Value="#FFFFFF" />
            <Setter Property="BorderBrush" Value="#E5E5EA" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="CornerRadius" Value="14" />
            <Setter Property="Padding" Value="22,18" />
            <Setter Property="Margin" Value="0,0,0,14" />
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect Color="#000000" BlurRadius="18" ShadowDepth="2" Opacity="0.07" />
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="CommandBar" TargetType="Border">
            <Setter Property="Background" Value="#FFFFFF" />
            <Setter Property="BorderBrush" Value="#D9E2EC" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="CornerRadius" Value="12" />
            <Setter Property="Padding" Value="10,8" />
        </Style>
        <Style x:Key="NavigationButton" TargetType="Button">
            <Setter Property="Background" Value="#F2F2F7" />
            <Setter Property="BorderBrush" Value="Transparent" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="Padding" Value="10,9" />
            <Setter Property="HorizontalContentAlignment" Value="Stretch" />
            <Setter Property="Cursor" Value="Hand" />
            <Setter Property="FocusVisualStyle" Value="{x:Null}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="NavigationChrome" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="12" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Stretch" VerticalAlignment="Center" />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="NavigationChrome" Property="Background" Value="#E9EEF5" /></Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="NavigationChrome" Property="BorderBrush" Value="#003F7D" /><Setter TargetName="NavigationChrome" Property="BorderThickness" Value="3" /></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.58" /></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="BorderBrush" Value="#D1D1D6" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="Padding" Value="12,8" />
            <Setter Property="MinHeight" Value="40" />
            <Setter Property="Background" Value="#FFFFFF" />
            <Setter Property="Foreground" Value="#1D1D1F" />
            <Setter Property="VerticalContentAlignment" Value="Center" />
            <Setter Property="CaretBrush" Value="#007AFF" />
            <Setter Property="SelectionBrush" Value="#B7D8FF" />
            <Setter Property="FocusVisualStyle" Value="{x:Null}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border x:Name="InputChrome" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="10" Padding="{TemplateBinding Padding}">
                            <ScrollViewer x:Name="PART_ContentHost" />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="InputChrome" Property="BorderBrush" Value="#AEAEB2" /></Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="InputChrome" Property="BorderBrush" Value="#0066D6" /><Setter TargetName="InputChrome" Property="BorderThickness" Value="3" /></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="InputChrome" Property="Background" Value="#F2F2F7" /><Setter Property="Foreground" Value="#8E8E93" /></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="PasswordBox">
            <Setter Property="BorderBrush" Value="#D1D1D6" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="Padding" Value="12,8" />
            <Setter Property="MinHeight" Value="40" />
            <Setter Property="Background" Value="#FFFFFF" />
            <Setter Property="Foreground" Value="#1D1D1F" />
            <Setter Property="VerticalContentAlignment" Value="Center" />
            <Setter Property="CaretBrush" Value="#007AFF" />
            <Setter Property="SelectionBrush" Value="#B7D8FF" />
            <Setter Property="FocusVisualStyle" Value="{x:Null}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="PasswordBox">
                        <Border x:Name="PasswordChrome" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="10" Padding="{TemplateBinding Padding}">
                            <ScrollViewer x:Name="PART_ContentHost" />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="PasswordChrome" Property="BorderBrush" Value="#AEAEB2" /></Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="PasswordChrome" Property="BorderBrush" Value="#0066D6" /><Setter TargetName="PasswordChrome" Property="BorderThickness" Value="3" /></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="PasswordChrome" Property="Background" Value="#F2F2F7" /><Setter Property="Foreground" Value="#8E8E93" /></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="BorderBrush" Value="#D1D1D6" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="Padding" Value="12,8" />
            <Setter Property="MinHeight" Value="40" />
            <Setter Property="Background" Value="#FFFFFF" />
            <Setter Property="Foreground" Value="#1D1D1F" />
            <Setter Property="FocusVisualStyle" Value="{x:Null}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <ToggleButton Focusable="False" ClickMode="Press"
                                          IsChecked="{Binding IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}">
                                <ToggleButton.Template>
                                    <ControlTemplate TargetType="ToggleButton">
                                        <Border Background="{Binding Background, RelativeSource={RelativeSource AncestorType=ComboBox}}"
                                                BorderBrush="{Binding BorderBrush, RelativeSource={RelativeSource AncestorType=ComboBox}}"
                                                BorderThickness="{Binding BorderThickness, RelativeSource={RelativeSource AncestorType=ComboBox}}"
                                                CornerRadius="10" />
                                    </ControlTemplate>
                                </ToggleButton.Template>
                            </ToggleButton>
                            <ContentPresenter Margin="12,0,36,0" VerticalAlignment="Center" HorizontalAlignment="Left"
                                              Content="{TemplateBinding SelectionBoxItem}"
                                              ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                              ContentStringFormat="{TemplateBinding SelectionBoxItemStringFormat}"
                                              IsHitTestVisible="False" />
                            <Path Data="M 0 0 L 4 4 L 8 0" Stroke="#6E6E73" StrokeThickness="1.5"
                                  HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,14,0" IsHitTestVisible="False" />
                            <Popup x:Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}"
                                   AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
                                <Border Background="#FFFFFF" BorderBrush="#D1D1D6" BorderThickness="1" CornerRadius="10" Padding="4" Margin="0,4,0,0">
                                    <Border.Effect><DropShadowEffect Color="#000000" BlurRadius="20" ShadowDepth="4" Opacity="0.14" /></Border.Effect>
                                    <ScrollViewer MaxHeight="300" CanContentScroll="True">
                                        <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Contained" />
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsEnabled" Value="False"><Setter Property="Background" Value="#F2F2F7" /><Setter Property="Foreground" Value="#8E8E93" /></Trigger>
                            <Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter Property="BorderBrush" Value="#0066D6" /><Setter Property="BorderThickness" Value="3" /></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="ComboBoxItem">
            <Setter Property="Padding" Value="11,8" />
            <Setter Property="Margin" Value="0,1" />
            <Setter Property="FocusVisualStyle" Value="{x:Null}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBoxItem">
                        <Border x:Name="ItemChrome" Background="Transparent" CornerRadius="7" Padding="{TemplateBinding Padding}">
                            <ContentPresenter VerticalAlignment="Center" />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="ItemChrome" Property="Background" Value="#F2F2F7" /></Trigger>
                            <Trigger Property="IsSelected" Value="True"><Setter TargetName="ItemChrome" Property="Background" Value="#EAF3FF" /><Setter Property="Foreground" Value="#0066D6" /></Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="ItemChrome" Property="BorderBrush" Value="#0066D6" /><Setter TargetName="ItemChrome" Property="BorderThickness" Value="2" /></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}" />
            <Setter Property="FocusVisualStyle" Value="{x:Null}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <StackPanel Orientation="Horizontal">
                            <Border x:Name="CheckChrome" Width="19" Height="19" CornerRadius="5" Background="#FFFFFF" BorderBrush="#C7C7CC" BorderThickness="1">
                                <TextBlock x:Name="CheckMark" Text="&#x2713;" Foreground="White" FontSize="13" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed" />
                            </Border>
                            <ContentPresenter Margin="8,0,0,0" VerticalAlignment="Center" RecognizesAccessKey="True" />
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True"><Setter TargetName="CheckChrome" Property="Background" Value="#007AFF" /><Setter TargetName="CheckChrome" Property="BorderBrush" Value="#007AFF" /><Setter TargetName="CheckMark" Property="Visibility" Value="Visible" /></Trigger>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="CheckChrome" Property="BorderBrush" Value="#007AFF" /></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.68" /></Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="CheckChrome" Property="BorderBrush" Value="#003F7D" /><Setter TargetName="CheckChrome" Property="BorderThickness" Value="3" /></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="ToggleButton">
            <Setter Property="Background" Value="#FFFFFF" />
            <Setter Property="Foreground" Value="#1D1D1F" />
            <Setter Property="BorderBrush" Value="#D1D1D6" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="Padding" Value="14,8" />
            <Setter Property="FontWeight" Value="SemiBold" />
            <Setter Property="Cursor" Value="Hand" />
            <Setter Property="FocusVisualStyle" Value="{x:Null}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Border x:Name="ToggleChrome" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="10" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ToggleChrome" Property="Background" Value="#F2F2F7" /></Trigger>
                            <Trigger Property="IsChecked" Value="True"><Setter TargetName="ToggleChrome" Property="Background" Value="#EAF3FF" /><Setter TargetName="ToggleChrome" Property="BorderBrush" Value="#8FC2FF" /><Setter Property="Foreground" Value="#0066D6" /></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5" /></Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="ToggleChrome" Property="BorderBrush" Value="#003F7D" /><Setter TargetName="ToggleChrome" Property="BorderThickness" Value="3" /></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="DataGrid">
            <Setter Property="Background" Value="#FFFFFF" />
            <Setter Property="Foreground" Value="#1D1D1F" />
            <Setter Property="BorderThickness" Value="0" />
            <Setter Property="RowBackground" Value="#FFFFFF" />
            <Setter Property="AlternatingRowBackground" Value="#FBFBFD" />
            <Setter Property="HorizontalGridLinesBrush" Value="#EFEFF1" />
            <Setter Property="VerticalGridLinesBrush" Value="Transparent" />
            <Setter Property="GridLinesVisibility" Value="Horizontal" />
            <Setter Property="HeadersVisibility" Value="Column" />
            <Setter Property="RowHeight" Value="42" />
            <Setter Property="ColumnHeaderHeight" Value="42" />
            <Setter Property="RowHeaderWidth" Value="0" />
            <Setter Property="CanUserAddRows" Value="False" />
            <Setter Property="CanUserDeleteRows" Value="False" />
            <Setter Property="CanUserResizeRows" Value="False" />
            <Setter Property="IsReadOnly" Value="True" />
            <Setter Property="HorizontalScrollBarVisibility" Value="Disabled" />
            <Setter Property="VerticalScrollBarVisibility" Value="Auto" />
        </Style>
        <Style TargetType="DataGridColumnHeader">
            <Setter Property="Background" Value="#F8F8FA" />
            <Setter Property="Foreground" Value="#6E6E73" />
            <Setter Property="FontWeight" Value="SemiBold" />
            <Setter Property="FontSize" Value="12" />
            <Setter Property="Padding" Value="12,0" />
            <Setter Property="BorderBrush" Value="#E5E5EA" />
            <Setter Property="BorderThickness" Value="0,0,0,1" />
        </Style>
        <Style TargetType="DataGridCell">
            <Setter Property="Padding" Value="11,0" />
            <Setter Property="BorderThickness" Value="0" />
            <Setter Property="VerticalContentAlignment" Value="Center" />
            <Style.Triggers>
                <Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter Property="BorderBrush" Value="#0066D6" /><Setter Property="BorderThickness" Value="2" /></Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="DataGridRow">
            <Setter Property="BorderThickness" Value="0" />
            <Setter Property="FocusVisualStyle" Value="{x:Null}" />
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#F2F7FF" /></Trigger>
                <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#DCEBFF" /><Setter Property="Foreground" Value="#1D1D1F" /></Trigger>
                <Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter Property="BorderBrush" Value="#0066D6" /><Setter Property="BorderThickness" Value="2" /></Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="TabControl">
            <Setter Property="Background" Value="Transparent" />
            <Setter Property="BorderThickness" Value="0" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TabControl">
                        <Grid>
                            <Grid.RowDefinitions><RowDefinition Height="Auto" /><RowDefinition Height="*" /></Grid.RowDefinitions>
                            <Border Background="#E9E9EE" CornerRadius="12" Padding="3" HorizontalAlignment="Left">
                                <TabPanel x:Name="HeaderPanel" IsItemsHost="True" Background="Transparent" />
                            </Border>
                            <ContentPresenter x:Name="PART_SelectedContentHost" Grid.Row="1" Margin="0,12,0,0"
                                              Content="{TemplateBinding SelectedContent}"
                                              ContentTemplate="{TemplateBinding SelectedContentTemplate}"
                                              ContentStringFormat="{TemplateBinding SelectedContentStringFormat}"
                                              HorizontalAlignment="Stretch" VerticalAlignment="Stretch" />
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="TabItem">
            <Setter Property="Foreground" Value="#6E6E73" />
            <Setter Property="FontWeight" Value="SemiBold" />
            <Setter Property="FocusVisualStyle" Value="{x:Null}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TabItem">
                        <Border x:Name="TabChrome" Background="Transparent" CornerRadius="9" Padding="16,8" Margin="1">
                            <ContentPresenter ContentSource="Header" HorizontalAlignment="Center" VerticalAlignment="Center" />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="TabChrome" Property="Background" Value="#F2F2F7" /></Trigger>
                            <Trigger Property="IsSelected" Value="True"><Setter TargetName="TabChrome" Property="Background" Value="#FFFFFF" /><Setter Property="Foreground" Value="#1D1D1F" /></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5" /></Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="TabChrome" Property="BorderBrush" Value="#003F7D" /><Setter TargetName="TabChrome" Property="BorderThickness" Value="3" /></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="244" />
            <ColumnDefinition Width="*" />
        </Grid.ColumnDefinitions>

        <Grid Grid.Column="0" Background="#F2F2F7">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto" />
                <RowDefinition Height="*" />
                <RowDefinition Height="Auto" />
            </Grid.RowDefinitions>
            <Border Grid.RowSpan="3" HorizontalAlignment="Right" Width="1" Background="#E5E5EA" />
            <Grid Margin="20,24,18,30">
                <Grid.ColumnDefinitions><ColumnDefinition Width="44" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions>
                <Border Width="38" Height="38" Background="#007AFF" CornerRadius="11" VerticalAlignment="Center">
                    <TextBlock Text="P" Foreground="White" FontSize="21" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center" />
                </Border>
                <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="4,0,0,0">
                    <TextBlock Text="Passbolt" Foreground="#1D1D1F" FontFamily="Segoe UI Variable Display, Segoe UI" FontSize="21" FontWeight="SemiBold" />
                    <TextBlock Text="Migration Assistant" Foreground="#8E8E93" FontSize="11" Margin="0,1,0,0" />
                </StackPanel>
            </Grid>
            <StackPanel Grid.Row="1" Margin="10,0">
                <Button x:Name="StepConfiguration" Style="{StaticResource NavigationButton}" Background="#FFFFFF" Margin="0,3" AutomationProperties.Name="Apri fase 01, preparazione locale">
                    <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="36" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions><Border Width="27" Height="27" Background="#EAF3FF" CornerRadius="9"><TextBlock x:Name="StepConfigurationNumber" Text="01" Foreground="#007AFF" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center" /></Border><TextBlock x:Name="StepConfigurationText" Grid.Column="1" Text="Configurazione" Foreground="#1D1D1F" FontWeight="SemiBold" VerticalAlignment="Center" /></Grid>
                </Button>
                <Button x:Name="StepInventory" Style="{StaticResource NavigationButton}" Margin="0,3" IsEnabled="False" AutomationProperties.Name="Apri fase 02, inventario file">
                    <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="36" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions><Border Width="27" Height="27" Background="#E5E5EA" CornerRadius="9"><TextBlock x:Name="StepInventoryNumber" Text="02" Foreground="#8E8E93" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center" /></Border><TextBlock x:Name="StepInventoryText" Grid.Column="1" Text="Inventario file" Foreground="#8E8E93" VerticalAlignment="Center" /></Grid>
                </Button>
                <Button x:Name="StepReview" Style="{StaticResource NavigationButton}" Margin="0,3" IsEnabled="False" AutomationProperties.Name="Apri fase 03, revisione"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="36" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions><Border Width="27" Height="27" Background="#E5E5EA" CornerRadius="9"><TextBlock x:Name="StepReviewNumber" Text="03" Foreground="#8E8E93" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center" /></Border><TextBlock x:Name="StepReviewText" Grid.Column="1" Text="Revisione" Foreground="#8E8E93" VerticalAlignment="Center" /></Grid></Button>
                <Button x:Name="StepImport" Style="{StaticResource NavigationButton}" Margin="0,3" IsEnabled="False" AutomationProperties.Name="Apri fase 04, operazioni Passbolt"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="36" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions><Border Width="27" Height="27" Background="#E5E5EA" CornerRadius="9"><TextBlock x:Name="StepImportNumber" Text="04" Foreground="#8E8E93" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center" /></Border><TextBlock x:Name="StepImportText" Grid.Column="1" Text="Operazioni Passbolt" Foreground="#8E8E93" VerticalAlignment="Center" /></Grid></Button>
            </StackPanel>
            <Border Grid.Row="2" Background="#EAF8F0" BorderBrush="#CAEAD8" BorderThickness="1" CornerRadius="14" Padding="16" Margin="14,18">
                <StackPanel>
                    <TextBlock Text="PROTEZIONE ATTIVA" Foreground="#248A3D" FontSize="10" FontWeight="SemiBold" />
                    <TextBlock x:Name="SafeModeText" Text="L&#x2019;inventario usa soltanto metadati. Il contenuto dei documenti non viene aperto." Foreground="#3A3A3C" FontSize="11" TextWrapping="Wrap" Margin="0,6,0,0" LineHeight="16" />
                </StackPanel>
            </Border>
        </Grid>

        <Grid Grid.Column="1" Background="#F5F5F7">
            <ScrollViewer x:Name="ConfigurationPage" VerticalScrollBarVisibility="Auto">
                <Grid Margin="38,32">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto" />
                        <RowDefinition Height="Auto" />
                        <RowDefinition Height="Auto" />
                    </Grid.RowDefinitions>
                    <Grid Grid.Row="0" Margin="0,0,0,24">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                        <StackPanel>
                            <TextBlock Text="Preparazione locale" Style="{StaticResource PageTitle}" />
                            <TextBlock Text="Scegli la cartella sorgente. Inventario e revisione funzionano senza collegarsi a Passbolt." Style="{StaticResource PageSubtitle}" TextWrapping="Wrap" />
                        </StackPanel>
                        <Button x:Name="OpenProjectButton" Grid.Column="1" Content="Apri progetto..." Style="{StaticResource SecondaryButton}" Margin="0,0,10,0" ToolTip="Ripristina una preparazione protetta per l'utente Windows corrente; connessione e contenuti saranno verificati di nuovo" />
                        <Border Grid.Column="2" Style="{StaticResource StatusPill}">
                            <TextBlock Text="NESSUNA CONNESSIONE REMOTA" Foreground="#196C2E" FontSize="11" FontWeight="SemiBold" />
                        </Border>
                    </Grid>

                    <Border Grid.Row="1" Style="{StaticResource Card}" Padding="24,20">
                        <StackPanel>
                            <TextBlock Text="1. Cartella documenti clienti" Style="{StaticResource SectionTitle}" />
                            <TextBlock Text="Ogni cartella di primo livello viene considerata un cliente. I file nella radice restano separati." Foreground="{StaticResource MutedBrush}" Margin="0,5,0,16" TextWrapping="Wrap" />
                            <Grid>
                                <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                                <TextBox x:Name="ClientFolder" AutomationProperties.Name="Cartella documenti clienti" />
                                <Button x:Name="BrowseButton" Grid.Column="1" Content="Scegli cartella" Style="{StaticResource SecondaryButton}" Margin="12,0,0,0" />
                            </Grid>
                            <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                                <Ellipse x:Name="FolderDot" Width="9" Height="9" Fill="#98A5B1" Margin="0,0,7,0" />
                                <TextBlock x:Name="FolderStatus" Text="Nessuna cartella selezionata" Foreground="{StaticResource MutedBrush}" />
                            </StackPanel>
                            <Border Height="1" Background="#E5E5EA" Margin="0,18,0,16" />
                            <TextBlock Text="Destinazione prevista (facoltativa)" FontWeight="SemiBold" />
                            <TextBlock Text="Puoi indicare ora l'URL HTTPS da conservare nel progetto locale oppure completarlo in fase 04. Serve solo per salvare un progetto; nessuna verifica viene eseguita qui." Foreground="{StaticResource MutedBrush}" FontSize="11" Margin="0,4,0,10" TextWrapping="Wrap" />
                            <TextBox x:Name="PlannedPassboltUrl" AutomationProperties.Name="URL Passbolt pianificato" ToolTip="URL base HTTPS, ad esempio https://passbolt.example.com; verrà verificato solo in fase 04" />
                        </StackPanel>
                    </Border>

                    <Grid Grid.Row="2" Margin="0,4,0,0">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                        <StackPanel VerticalAlignment="Center">
                            <CheckBox Content="Preparazione locale" IsChecked="True" IsEnabled="False" />
                            <TextBlock Text="La fase successiva raccoglie esclusivamente metadati dei file; Passbolt verrà verificato in fase 04." Foreground="{StaticResource MutedBrush}" FontSize="11" Margin="27,4,0,0" />
                        </StackPanel>
                        <Button x:Name="ContinueButton" Grid.Column="1" Content="Continua all&#x2019;inventario  &#x2192;" Style="{StaticResource PrimaryButton}" IsEnabled="False" Padding="22,12" />
                    </Grid>
                </Grid>
            </ScrollViewer>

            <Grid x:Name="InventoryPage" Visibility="Collapsed" Margin="34,28,34,26">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto" />
                    <RowDefinition Height="Auto" />
                    <RowDefinition Height="Auto" />
                    <RowDefinition Height="*" />
                    <RowDefinition Height="Auto" />
                </Grid.RowDefinitions>

                <Grid Grid.Row="0" Margin="0,0,0,16">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /><ColumnDefinition Width="Auto" /><ColumnDefinition Width="Auto" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                    <StackPanel>
                        <TextBlock Text="Inventario file" Style="{StaticResource PageTitle}" />
                        <TextBlock x:Name="InventoryRoot" Text="Inventario non ancora eseguito" Style="{StaticResource PageSubtitle}" FontSize="12" TextTrimming="CharacterEllipsis" />
                    </StackPanel>
                    <Button x:Name="RefreshButton" Grid.Column="1" Content="Aggiorna inventario" Style="{StaticResource SecondaryButton}" VerticalAlignment="Center" />
                    <Button x:Name="ExportButton" Grid.Column="2" Content="Esporta CSV" Style="{StaticResource SecondaryButton}" Margin="8,0,0,0" VerticalAlignment="Center" IsEnabled="False" />
                    <Button x:Name="SourceProfileButton" Grid.Column="3" Content="Profilo sorgente: Automatico" Style="{StaticResource SecondaryButton}" Margin="8,0,0,0" VerticalAlignment="Center" ToolTip="Configura etichette sorgente esatte, senza salvare valori delle credenziali" />
                    <Button x:Name="ReviewSelectionButton" Grid.Column="4" Content="Rivedi selezionati (0)" Style="{StaticResource PrimaryButton}" Margin="8,0,0,0" VerticalAlignment="Center" IsEnabled="False" />
                </Grid>

                <Grid Grid.Row="1" Margin="0,0,0,12">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="*" /><ColumnDefinition Width="*" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions>
                    <Border Grid.Column="0" Style="{StaticResource Card}" Margin="0,0,5,0"><StackPanel><TextBlock Text="Clienti individuati" Foreground="#66737F" /><TextBlock x:Name="MetricClients" Text="&#x2014;" FontSize="24" FontWeight="Bold" Foreground="#1F2933" /></StackPanel></Border>
                    <Border Grid.Column="1" Style="{StaticResource Card}" Margin="5,0"><StackPanel><TextBlock Text="File supportati" Foreground="#66737F" /><TextBlock x:Name="MetricFiles" Text="&#x2014;" FontSize="24" FontWeight="Bold" Foreground="#1F2933" /></StackPanel></Border>
                    <Border Grid.Column="2" Style="{StaticResource Card}" Margin="5,0"><StackPanel><TextBlock Text="Dimensione indicizzata" Foreground="#66737F" /><TextBlock x:Name="MetricSize" Text="&#x2014;" FontSize="24" FontWeight="Bold" Foreground="#1F2933" /></StackPanel></Border>
                    <Border Grid.Column="3" Style="{StaticResource Card}" Margin="5,0,0,0"><StackPanel><TextBlock Text="File ignorati" Foreground="#66737F" /><TextBlock x:Name="MetricIgnored" Text="&#x2014;" FontSize="24" FontWeight="Bold" Foreground="#1F2933" /></StackPanel></Border>
                </Grid>

                <Border Grid.Row="2" Style="{StaticResource Card}" Padding="14,12">
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="180" /><ColumnDefinition Width="160" /><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                        <ComboBox x:Name="ClientFilter" Grid.Column="0" AutomationProperties.Name="Filtro cliente inventario" />
                        <ComboBox x:Name="FormatFilter" Grid.Column="1" Margin="8,0,0,0" AutomationProperties.Name="Filtro formato inventario" />
                        <TextBox x:Name="SearchBox" Grid.Column="2" Margin="8,0,0,0" AutomationProperties.Name="Ricerca file inventariati" ToolTip="Cerca nel cliente o nel percorso relativo" />
                        <TextBlock x:Name="FilterStatus" Grid.Column="3" Text="0 file" Foreground="#66737F" VerticalAlignment="Center" Margin="14,0,0,0" />
                    </Grid>
                </Border>

                <Border Grid.Row="3" Style="{StaticResource Card}" Margin="0" Padding="0">
                    <Grid>
                        <Grid.RowDefinitions><RowDefinition Height="*" /><RowDefinition Height="Auto" /></Grid.RowDefinitions>
                        <DataGrid x:Name="FilesGrid" Grid.Row="0" AutoGenerateColumns="False" AlternationCount="2" SelectionMode="Extended" SelectionUnit="FullRow" HorizontalScrollBarVisibility="Auto" AutomationProperties.Name="File inventariati" ToolTip="Seleziona pi&#xF9; file con Ctrl o Maiusc" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling">
                            <DataGrid.Columns>
                                <DataGridTextColumn Header="Cliente" Binding="{Binding Client}" Width="145" />
                                <DataGridTextColumn Header="Percorso relativo" Binding="{Binding RelativePath}" Width="*" MinWidth="360" />
                                <DataGridTextColumn Header="Formato" Binding="{Binding Extension}" Width="78" />
                                <DataGridTextColumn Header="Categoria" Binding="{Binding Category}" Width="118" />
                                <DataGridTextColumn Header="Dimensione" Binding="{Binding Size}" Width="92" />
                                <DataGridTextColumn Header="Modificato" Binding="{Binding Modified}" Width="132" />
                            </DataGrid.Columns>
                        </DataGrid>
                        <Border x:Name="WarningsPanel" Grid.Row="1" Style="{StaticResource WarningBanner}" Visibility="Collapsed">
                            <TextBlock x:Name="WarningsText" Foreground="#8A5A00" FontSize="11" TextWrapping="Wrap" />
                        </Border>
                    </Grid>
                </Border>

                <Grid Grid.Row="4" Margin="0,12,0,0">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto" /><ColumnDefinition Width="Auto" /><ColumnDefinition Width="Auto" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions>
                    <Button x:Name="BackButton" Content="&#x2190;  Torna alla configurazione" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="SaveInventoryProjectButton" Grid.Column="1" Content="Salva progetto..." Style="{StaticResource SecondaryButton}" Margin="8,0,0,0" IsEnabled="False" ToolTip="Salva origine, cartella, profilo e file selezionati in un progetto DPAPI privo di credenziali" />
                    <Button x:Name="SourceFeedbackButton" Grid.Column="2" Content="Esclusioni e conversioni" Style="{StaticResource SecondaryButton}" Margin="8,0,0,0" IsEnabled="False" ToolTip="Mostra soltanto conteggi aggregati per motivo e formato, senza nomi o percorsi" />
                    <TextBox x:Name="ActivityLog" Grid.Column="3" Margin="12,0,0,0" Height="42" IsReadOnly="True" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" AutomationProperties.Name="Registro attivita locale" FontFamily="Cascadia Mono, Consolas" FontSize="10" Background="#F2F2F7" BorderBrush="#E5E5EA" />
                </Grid>
            </Grid>

            <Grid x:Name="ReviewPage" Visibility="Collapsed" Margin="34,28,34,26">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto" />
                    <RowDefinition Height="Auto" />
                    <RowDefinition Height="Auto" />
                    <RowDefinition Height="*" />
                    <RowDefinition Height="Auto" />
                </Grid.RowDefinitions>

                <Grid Grid.Row="0" Margin="0,0,0,16">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                    <StackPanel>
                        <TextBlock Text="Revisione controllata" Style="{StaticResource PageTitle}" />
                        <TextBlock x:Name="ReviewSummary" Text="Nessuna revisione eseguita" Style="{StaticResource PageSubtitle}" FontSize="12" />
                    </StackPanel>
                    <Border Grid.Column="1" Style="{StaticResource StatusPill}">
                        <TextBlock x:Name="ReviewPasswordState" Text="PASSWORD MASCHERATE" Foreground="#248A3D" FontSize="10" FontWeight="SemiBold" />
                    </Border>
                </Grid>

                <Grid Grid.Row="1" Margin="0,0,0,12">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="*" /><ColumnDefinition Width="*" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions>
                    <Border Grid.Column="0" Style="{StaticResource Card}" Margin="0,0,5,0"><StackPanel><TextBlock Text="File analizzati" Foreground="#66737F" /><TextBlock x:Name="ReviewMetricFiles" Text="&#x2014;" FontSize="24" FontWeight="Bold" Foreground="#1F2933" /></StackPanel></Border>
                    <Border Grid.Column="1" Style="{StaticResource Card}" Margin="5,0"><StackPanel><TextBlock Text="Candidati" Foreground="#66737F" /><TextBlock x:Name="ReviewMetricCandidates" Text="&#x2014;" FontSize="24" FontWeight="Bold" Foreground="#1F2933" /></StackPanel></Border>
                    <Border Grid.Column="2" Style="{StaticResource Card}" Margin="5,0"><StackPanel><TextBlock Text="Pronti" Foreground="#66737F" /><TextBlock x:Name="ReviewMetricReady" Text="&#x2014;" FontSize="24" FontWeight="Bold" Foreground="#16875D" /></StackPanel></Border>
                    <Border Grid.Column="3" Style="{StaticResource Card}" Margin="5,0,0,0"><StackPanel><TextBlock Text="Da completare" Foreground="#66737F" /><TextBlock x:Name="ReviewMetricIncomplete" Text="&#x2014;" FontSize="24" FontWeight="Bold" Foreground="#B7791F" /></StackPanel></Border>
                </Grid>

                <Border Grid.Row="2" Style="{StaticResource Card}" Padding="14,12">
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="170" /><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /><ColumnDefinition Width="Auto" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                        <ComboBox x:Name="ReviewStatusFilter" Grid.Column="0" AutomationProperties.Name="Filtro stato candidati" />
                        <TextBox x:Name="ReviewSearchBox" Grid.Column="1" Margin="8,0,0,0" AutomationProperties.Name="Ricerca candidati" ToolTip="Cerca in cliente, titolo, username, URL o origine" />
                        <ToggleButton x:Name="ReviewPasswordToggle" Grid.Column="2" Content="Mostra password" Margin="8,0,0,0" Padding="12,7" VerticalAlignment="Stretch" ToolTip="Mostra temporaneamente le password dei candidati caricandole soltanto in memoria" />
                        <Button x:Name="EditReviewCandidateButton" Grid.Column="3" Content="Modifica..." Style="{StaticResource SecondaryButton}" Margin="8,0,0,0" Padding="14,7" IsEnabled="False" ToolTip="Modifica il candidato selezionato prima dell'importazione" />
                        <TextBlock x:Name="ReviewFilterStatus" Grid.Column="4" Text="0 candidati" Foreground="#66737F" VerticalAlignment="Center" Margin="14,0,0,0" />
                    </Grid>
                </Border>

                <Border Grid.Row="3" Style="{StaticResource Card}" Margin="0" Padding="0">
                    <Grid>
                        <Grid.RowDefinitions><RowDefinition Height="*" /><RowDefinition Height="Auto" /></Grid.RowDefinitions>
                        <DataGrid x:Name="ReviewCandidatesGrid" Grid.Row="0" AutoGenerateColumns="False" AlternationCount="2" SelectionMode="Extended" SelectionUnit="FullRow" HorizontalScrollBarVisibility="Auto" AutomationProperties.Name="Candidati revisionati" ToolTip="Seleziona i candidati pronti con Ctrl o Maiusc" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling">
                            <DataGrid.Columns>
                                <DataGridTextColumn Header="Stato" Binding="{Binding StatusLabel}" Width="105" />
                                <DataGridTextColumn Header="Cliente" Binding="{Binding Client}" Width="125" />
                                <DataGridTextColumn Header="Titolo" Binding="{Binding Title}" Width="150" />
                                <DataGridTextColumn Header="Username" Binding="{Binding Username}" Width="135" />
                                <DataGridTextColumn Header="URL / host" Binding="{Binding Uri}" Width="*" MinWidth="180" />
                                <DataGridTextColumn Header="Password" Binding="{Binding SecretDisplay}" Width="130" />
                                <DataGridTextColumn Header="Origine" Binding="{Binding Source}" Width="180" />
                            </DataGrid.Columns>
                        </DataGrid>
                        <Border x:Name="ReviewWarningsPanel" Grid.Row="1" Style="{StaticResource WarningBanner}" Visibility="Collapsed">
                            <TextBlock x:Name="ReviewWarningsText" Foreground="#8A5A00" FontSize="11" TextWrapping="Wrap" MaxHeight="62" />
                        </Border>
                    </Grid>
                </Border>

                <Grid Grid.Row="4" Margin="0,12,0,0">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto" /><ColumnDefinition Width="Auto" /><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                    <Button x:Name="ReviewBackButton" Content="&#x2190;  Torna all&#x2019;inventario" Style="{StaticResource SecondaryButton}" />
                    <Button x:Name="SaveReviewProjectButton" Grid.Column="1" Content="Salva progetto..." Style="{StaticResource SecondaryButton}" Margin="8,0,0,0" IsEnabled="False" ToolTip="Salva anche le sole prove tecniche dei candidati pronti selezionati; valori e correzioni restano esclusi" />
                    <TextBlock Grid.Column="2" Text="Le password sono mascherate per impostazione predefinita; quando richieste restano solo in memoria e non vengono salvate o registrate." Foreground="#66737F" FontSize="11" VerticalAlignment="Center" Margin="14,0" TextWrapping="Wrap" />
                    <Button x:Name="PrepareImportButton" Grid.Column="3" Content="Prepara importazione (0)" Style="{StaticResource PrimaryButton}" IsEnabled="False" />
                </Grid>
            </Grid>

            <Grid x:Name="ImportPage" Visibility="Collapsed" Margin="28,20,28,20">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto" />
                    <RowDefinition Height="Auto" />
                    <RowDefinition Height="*" />
                </Grid.RowDefinitions>

                <Grid Grid.Row="0" Margin="0,0,0,10">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                    <StackPanel>
                        <TextBlock x:Name="ImportPageTitle" Text="Importazione controllata" Style="{StaticResource PageTitle}" />
                        <TextBlock x:Name="ImportSummary" Text="Prepara i candidati dalla revisione" Style="{StaticResource PageSubtitle}" FontSize="12" />
                    </StackPanel>
                    <Button x:Name="AclWorkspaceButton" Grid.Column="1" Content="Gestisci ACL esistenti" Style="{StaticResource SecondaryButton}" Margin="0,0,10,0" ToolTip="Apre uno spazio separato dalla migrazione per consultare, simulare e applicare ACL sugli oggetti esistenti" />
                    <Border Grid.Column="2" Style="{StaticResource StatusPill}">
                        <TextBlock Text="V4 + RISORSE V5 PREVIEW" Foreground="#8A5A00" FontSize="11" FontWeight="SemiBold" />
                    </Border>
                </Grid>

                <Border Grid.Row="1" Style="{StaticResource Card}" Padding="16,13" Margin="0">
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="1.05*" /><ColumnDefinition Width="22" /><ColumnDefinition Width="0.95*" /></Grid.ColumnDefinitions>
                        <Border x:Name="Phase04SettingsSeparator" Grid.Column="1" Width="1" Background="#E5E5EA" HorizontalAlignment="Center" />

                        <Grid Grid.Column="0">
                            <Grid.RowDefinitions><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /></Grid.RowDefinitions>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="88" /><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                            <StackPanel Grid.Row="0" Grid.ColumnSpan="3" Margin="0,0,0,9">
                                <TextBlock Text="Passbolt e sessione sicura" Style="{StaticResource SectionTitle}" FontSize="16" />
                                <TextBlock Text="Verifica il server e conferma la fingerprint, poi apri GPGAuth. Credenziali e identit&#xE0; OpenPGP restano solo in memoria." Foreground="#66737F" FontSize="11" TextWrapping="Wrap" Margin="0,2,0,0" />
                            </StackPanel>
                            <TextBlock Grid.Row="1" Text="Server" Foreground="{StaticResource MutedBrush}" VerticalAlignment="Center" />
                            <TextBox x:Name="PassboltUrl" Grid.Row="1" Grid.Column="1" AutomationProperties.Name="URL HTTPS Passbolt" ToolTip="URL base HTTPS, ad esempio https://passbolt.example.com" MinHeight="34" Padding="10,6" />
                            <Button x:Name="VerifyButton" Grid.Row="1" Grid.Column="2" Content="Verifica" Style="{StaticResource PrimaryButton}" Margin="8,0,0,0" MinHeight="34" Padding="13,6" FontSize="12" IsEnabled="False" />
                            <Border Grid.Row="2" Grid.Column="1" Grid.ColumnSpan="2" Background="#F5F5F7" BorderBrush="#E5E5EA" BorderThickness="1" CornerRadius="9" Padding="9,6" Margin="0,6,0,0">
                                <Grid>
                                    <Grid.RowDefinitions><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /></Grid.RowDefinitions>
                                    <StackPanel Orientation="Horizontal">
                                        <Ellipse x:Name="ConnectionDot" Width="8" Height="8" Fill="#98A5B1" Margin="0,0,7,0" />
                                        <TextBlock x:Name="ConnectionStatus" Text="Server non verificato" Foreground="{StaticResource MutedBrush}" FontSize="11" TextWrapping="Wrap" />
                                    </StackPanel>
                                    <TextBlock x:Name="DetectedFingerprint" Grid.Row="1" Text="Fingerprint: non ancora rilevata" Foreground="#3A3A3C" FontFamily="Cascadia Mono, Consolas" FontSize="10" TextTrimming="CharacterEllipsis" ToolTip="Fingerprint OpenPGP del server rilevata durante la verifica pubblica" Margin="15,2,0,0" />
                                </Grid>
                            </Border>
                            <TextBlock Grid.Row="3" Text="Chiave privata" Foreground="{StaticResource MutedBrush}" VerticalAlignment="Center" Margin="0,6,0,0" />
                            <TextBox x:Name="PrivateKeyPath" Grid.Row="3" Grid.Column="1" AutomationProperties.Name="Percorso chiave privata OpenPGP" ToolTip="File ASCII-armored della chiave privata Passbolt" MinHeight="34" Padding="10,6" Margin="0,6,0,0" />
                            <Button x:Name="BrowseKeyButton" Grid.Row="3" Grid.Column="2" Content="Scegli file" Style="{StaticResource SecondaryButton}" Margin="8,6,0,0" MinHeight="34" Padding="13,6" FontSize="12" />
                            <Grid Grid.Row="4" Grid.ColumnSpan="3" Margin="0,6,0,0">
                                <Grid.ColumnDefinitions><ColumnDefinition Width="88" /><ColumnDefinition Width="*" /><ColumnDefinition Width="76" /><ColumnDefinition Width="76" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                                <TextBlock Text="Passphrase" Foreground="{StaticResource MutedBrush}" VerticalAlignment="Center" />
                                <PasswordBox x:Name="KeyPassphrase" Grid.Column="1" AutomationProperties.Name="Passphrase chiave privata" ToolTip="Usata solo per aprire la sessione; non viene salvata e il campo viene subito cancellato" MinHeight="34" Padding="10,6" />
                                <TextBlock Grid.Column="2" Text="MFA (TOTP)" Foreground="{StaticResource MutedBrush}" VerticalAlignment="Center" Margin="8,0,0,0" />
                                <PasswordBox x:Name="MfaTotpCode" Grid.Column="3" AutomationProperties.Name="Codice MFA TOTP" MaxLength="6" ToolTip="Usato solo per aprire la sessione; non viene salvato e il campo viene subito cancellato" MinHeight="34" Padding="10,6" />
                                <Button x:Name="ImportSessionButton" Grid.Column="4" Content="Avvia sessione" Style="{StaticResource SecondaryButton}" Margin="8,0,0,0" MinHeight="34" Padding="13,6" FontSize="12" />
                            </Grid>
                        </Grid>

                        <Grid x:Name="MigrationDestinationPanel" Grid.Column="2">
                            <Grid.RowDefinitions><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /></Grid.RowDefinitions>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="105" /><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                            <StackPanel Grid.Row="0" Grid.ColumnSpan="3" Margin="0,0,0,9">
                                <TextBlock Text="Destinazione migrazione" Style="{StaticResource SectionTitle}" FontSize="16" />
                                <TextBlock Text="Il preflight verifica destinazione, formato e permessi prima di ogni scrittura. Le risorse v5 personali sono opt-in; import v5 condivisi, cartelle v5, ACL mutative v5 e selezione automatica restano bloccati." Foreground="#66737F" FontSize="11" TextWrapping="Wrap" Margin="0,2,0,0" />
                            </StackPanel>
                            <TextBlock Grid.Row="1" Text="Destinazione" Foreground="{StaticResource MutedBrush}" VerticalAlignment="Center" />
                            <ComboBox x:Name="DestinationMode" Grid.Row="1" Grid.Column="1" Grid.ColumnSpan="2" AutomationProperties.Name="Modalità destinazione migrazione" SelectedIndex="0" ToolTip="Crea o riutilizza una cartella per ogni cliente; in un contenitore condiviso eredita la maschera dei permessi verificata" MinHeight="34" Padding="10,6">
                                <ComboBoxItem Content="Cartelle per cliente nel contenitore scelto" Tag="client_folders" />
                                <ComboBoxItem Content="Mappatura distinta per ogni cliente" Tag="client_mapping" />
                                <ComboBoxItem Content="Direttamente nella cartella scelta" Tag="direct_folder" />
                                <ComboBoxItem Content="Radice personale Passbolt" Tag="root" />
                            </ComboBox>
                            <TextBlock Grid.Row="2" Text="Cartella Passbolt" Foreground="{StaticResource MutedBrush}" VerticalAlignment="Center" Margin="0,8,0,0" />
                            <ComboBox x:Name="DestinationFolder" Grid.Row="2" Grid.Column="1" Grid.ColumnSpan="2" AutomationProperties.Name="Cartella Passbolt di destinazione" Margin="0,8,0,0" SelectedIndex="0" MaxDropDownHeight="300" ToolTip="Il primo dry-run carica le cartelle Passbolt accessibili" MinHeight="34" Padding="10,6">
                                <ComboBoxItem Content="Radice personale Passbolt" Tag="" />
                            </ComboBox>
                            <Button x:Name="ConfigureClientMappingsButton" Grid.Row="2" Grid.Column="1" Grid.ColumnSpan="2" HorizontalAlignment="Left" Content="Mappa clienti" Style="{StaticResource SecondaryButton}" Margin="0,8,0,0" IsEnabled="False" Visibility="Collapsed" MinHeight="34" Padding="13,6" FontSize="12" />
                            <TextBlock Grid.Row="3" Text="Permessi" Foreground="{StaticResource MutedBrush}" VerticalAlignment="Center" Margin="0,8,0,0" />
                            <TextBlock x:Name="PermissionModeStatus" Grid.Row="3" Grid.Column="1" Text="Ereditati dalla destinazione" Foreground="{StaticResource MutedBrush}" VerticalAlignment="Center" Margin="0,8,8,0" TextWrapping="Wrap" ToolTip="I permessi personalizzati vengono applicati soltanto alle nuove cartelle e risorse; il proprietario autenticato resta sempre Owner" />
                            <Button x:Name="ConfigurePermissionsButton" Grid.Row="3" Grid.Column="2" Content="Modifica permessi..." Style="{StaticResource SecondaryButton}" Margin="0,8,0,0" IsEnabled="False" MinHeight="34" Padding="13,6" FontSize="12" />
                            <TextBlock Grid.Row="4" Text="Formato risorse" Foreground="{StaticResource MutedBrush}" VerticalAlignment="Center" Margin="0,8,0,0" />
                            <StackPanel Grid.Row="4" Grid.Column="1" Margin="0,8,8,0">
                                <ComboBox x:Name="ResourceFormat" AutomationProperties.Name="Formato risorse Passbolt" SelectedIndex="0" ToolTip="La scelta e' esplicita e viene legata al piano; non sono previsti auto-selezione o fallback silenziosi" MinHeight="34" Padding="10,6">
                                    <ComboBoxItem Content="v4 - metadati in chiaro" Tag="v4" />
                                    <ComboBoxItem Content="v5 preview personale - metadati cifrati" Tag="v5" />
                                </ComboBox>
                                <TextBlock Text="Cartelle: v4. La creazione di cartelle v5 resta bloccata." Foreground="#8A5A00" FontSize="10" TextWrapping="Wrap" Margin="2,4,0,0" />
                            </StackPanel>
                            <Button x:Name="DryRunButton" Grid.Row="4" Grid.Column="2" Content="Preflight e dry-run" Style="{StaticResource PrimaryButton}" Margin="0,8,0,0" IsEnabled="False" MinHeight="34" Padding="13,6" FontSize="12" />
                        </Grid>
                        <Grid x:Name="AclContextPanel" Grid.Column="2" Visibility="Collapsed">
                            <Grid.RowDefinitions><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /></Grid.RowDefinitions>
                            <StackPanel Grid.Row="0" Margin="0,0,0,9">
                                <TextBlock Text="Contesto ACL separato" Style="{StaticResource SectionTitle}" FontSize="16" />
                                <TextBlock Text="Le opzioni di destinazione della migrazione non si applicano agli oggetti esistenti." Foreground="#66737F" FontSize="11" TextWrapping="Wrap" Margin="0,2,0,0" />
                            </StackPanel>
                            <Border Grid.Row="1" Style="{StaticResource InfoBanner}" Padding="11,8" Margin="0,0,0,7">
                                <TextBlock Text="1. Il catalogo viene letto senza richieste di scrittura." Foreground="#355E85" FontSize="11" TextWrapping="Wrap" />
                            </Border>
                            <Border Grid.Row="2" Style="{StaticResource InfoBanner}" Padding="11,8" Margin="0,0,0,7">
                                <TextBlock Text="2. Ogni piano confronta una ACL desiderata con uno snapshot remoto fresco." Foreground="#355E85" FontSize="11" TextWrapping="Wrap" />
                            </Border>
                            <Border Grid.Row="3" Background="#FFF8E1" BorderBrush="#F2C94C" BorderThickness="1" CornerRadius="9" Padding="11,8">
                                <TextBlock Text="3. L'applicazione resta bloccata fino alla conferma esatta; gli oggetti v5 sono consultabili, ma import condivisi e ACL mutative v5 restano fuori scope." Foreground="#754C00" FontSize="11" TextWrapping="Wrap" />
                            </Border>
                        </Grid>
                    </Grid>
                </Border>

                <Grid Grid.Row="2" MinHeight="0" Margin="0,10,0,0">
                    <Grid x:Name="MigrationWorkspace">
                        <Grid.RowDefinitions><RowDefinition Height="Auto" /><RowDefinition Height="*" /></Grid.RowDefinitions>
                        <Grid Grid.Row="0">
                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto" /><ColumnDefinition Width="Auto" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions>
                            <ToggleButton x:Name="NewImportModeButton" Grid.Column="0" Content="Nuova importazione" IsChecked="True" MinHeight="34" Padding="14,7" />
                            <ToggleButton x:Name="RecoveryModeButton" Grid.Column="1" Content="Recupero import interrotto" Margin="8,0,0,0" MinHeight="34" Padding="14,7" />
                            <TextBlock Grid.Column="2" Text="Percorso di migrazione" Foreground="#66737F" FontSize="11" HorizontalAlignment="Right" VerticalAlignment="Center" />
                        </Grid>
                        <Grid Grid.Row="1" Margin="0,8,0,0">
                    <Grid x:Name="NewImportWorkspace">
                        <Grid Margin="6,0,6,6">
                            <Grid.RowDefinitions><RowDefinition Height="Auto" /><RowDefinition Height="*" /><RowDefinition Height="Auto" /></Grid.RowDefinitions>
                            <Grid Grid.Row="0" Margin="0,0,0,10">
                                <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="*" /><ColumnDefinition Width="*" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions>
                                <Border Grid.Column="0" Style="{StaticResource Card}" Margin="0,0,5,0" Padding="12,8"><StackPanel><TextBlock Text="Selezionati" Foreground="#66737F" FontSize="11" /><TextBlock x:Name="ImportMetricSelected" Text="&#x2014;" FontSize="18" FontWeight="Bold" Foreground="#1F2933" /></StackPanel></Border>
                                <Border Grid.Column="1" Style="{StaticResource Card}" Margin="5,0" Padding="12,8"><StackPanel><TextBlock Text="Da creare" Foreground="#66737F" FontSize="11" /><TextBlock x:Name="ImportMetricCreate" Text="&#x2014;" FontSize="18" FontWeight="Bold" Foreground="#16875D" /></StackPanel></Border>
                                <Border Grid.Column="2" Style="{StaticResource Card}" Margin="5,0" Padding="12,8"><StackPanel><TextBlock Text="Duplicati esatti" Foreground="#66737F" FontSize="11" /><TextBlock x:Name="ImportMetricDuplicates" Text="&#x2014;" FontSize="18" FontWeight="Bold" Foreground="#B7791F" /></StackPanel></Border>
                                <Border Grid.Column="3" Style="{StaticResource Card}" Margin="5,0,0,0" Padding="12,8"><StackPanel><TextBlock Text="Cartelle nuove" Foreground="#66737F" FontSize="11" /><TextBlock x:Name="ImportMetricExisting" Text="&#x2014;" FontSize="18" FontWeight="Bold" Foreground="#1F2933" /></StackPanel></Border>
                            </Grid>
                            <TabControl x:Name="ImportWorkspaceTabs" Grid.Row="1">
                                <TabItem Header="Piano">
                                    <Border Style="{StaticResource Card}" Margin="0" Padding="0">
                                        <Grid>
                                            <Grid.RowDefinitions><RowDefinition Height="Auto" /><RowDefinition Height="*" /><RowDefinition Height="Auto" /></Grid.RowDefinitions>
                                            <Border Grid.Row="0" Background="#F8F8FA" BorderBrush="#E5E5EA" BorderThickness="0,0,0,1" Padding="14,10">
                                                <TextBlock x:Name="ImportIdentity" Text="Eseguire il preflight per verificare identit&#xE0; e piano." Foreground="#66737F" FontSize="11" TextWrapping="Wrap" />
                                            </Border>
                                            <DataGrid x:Name="ImportPlanGrid" Grid.Row="1" AutoGenerateColumns="False" AlternationCount="2" SelectionMode="Single" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling">
                                                <DataGrid.Columns>
                                                    <DataGridTextColumn Header="Azione" Binding="{Binding ActionLabel}" Width="205" />
                                                    <DataGridTextColumn Header="Destinazione" Binding="{Binding Destination}" Width="190" />
                                                    <DataGridTextColumn Header="Titolo" Binding="{Binding Title}" Width="165" />
                                                    <DataGridTextColumn Header="Username" Binding="{Binding Username}" Width="150" />
                                                    <DataGridTextColumn Header="URL / host" Binding="{Binding Uri}" Width="*" MinWidth="180" />
                                                </DataGrid.Columns>
                                            </DataGrid>
                                            <Border Grid.Row="2" Style="{StaticResource WarningBanner}">
                                                <TextBlock x:Name="ImportPlanStatus" Text="Nessuna richiesta sar&#xE0; inviata finch&#xE9; non viene avviato il preflight." Foreground="#8A5A00" FontSize="11" TextWrapping="Wrap" />
                                            </Border>
                                        </Grid>
                                    </Border>
                                </TabItem>
                                <TabItem Header="Preflight">
                                    <Border Style="{StaticResource Card}" Margin="0" Padding="0">
                                        <Grid>
                                            <Grid.RowDefinitions><RowDefinition Height="Auto" /><RowDefinition Height="*" /></Grid.RowDefinitions>
                                            <Border Grid.Row="0" Style="{StaticResource InfoBanner}" Margin="10,10,10,6">
                                                <Grid>
                                                    <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                                                    <TextBlock x:Name="PreflightStatus" Text="Eseguire il preflight autenticato per controllare compatibilit&#xE0;, destinazione e permessi." Foreground="#355E85" FontSize="11" TextWrapping="Wrap" VerticalAlignment="Center" />
                                                    <Button x:Name="ExportPreflightReceiptButton" Grid.Column="1" Content="Esporta ricevuta..." Style="{StaticResource SecondaryButton}" Margin="10,0,0,0" Padding="11,6" MinHeight="32" FontSize="11" IsEnabled="False" ToolTip="Esporta solo digest, strategia logica, conteggi e stati dei controlli" />
                                                </Grid>
                                            </Border>
                                            <DataGrid x:Name="PreflightGrid" Grid.Row="1" AutoGenerateColumns="False" AlternationCount="2" SelectionMode="Single" IsReadOnly="True" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling">
                                                <DataGrid.Columns>
                                                    <DataGridTextColumn Header="Controllo" Binding="{Binding CheckLabel}" Width="210" />
                                                    <DataGridTextColumn Header="Esito" Binding="{Binding StatusLabel}" Width="125" />
                                                    <DataGridTextColumn Header="Dettaglio" Binding="{Binding Detail}" Width="*" MinWidth="340" />
                                                </DataGrid.Columns>
                                            </DataGrid>
                                        </Grid>
                                    </Border>
                                </TabItem>
                                <TabItem Header="Verifica finale">
                                    <Border Style="{StaticResource Card}" Margin="0" Padding="0">
                                        <Grid>
                                            <Grid.RowDefinitions><RowDefinition Height="Auto" /><RowDefinition Height="*" /></Grid.RowDefinitions>
                                            <Border Grid.Row="0" Style="{StaticResource InfoBanner}" Margin="10,10,10,6">
                                                <Grid>
                                                    <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                                                    <TextBlock x:Name="VerificationStatus" Text="Dopo l'importazione, ogni risorsa verr&#xE0; riletta e confrontata senza conservare password o hash dei segreti." Foreground="#355E85" FontSize="11" TextWrapping="Wrap" VerticalAlignment="Center" />
                                                    <Button x:Name="ExportMigrationReceiptButton" Grid.Column="1" Content="Esporta ricevuta..." Style="{StaticResource SecondaryButton}" Margin="10,0,0,0" Padding="11,6" MinHeight="32" FontSize="11" IsEnabled="False" ToolTip="Disponibile soltanto dopo verifica completa e chiusura del journal" />
                                                </Grid>
                                            </Border>
                                            <DataGrid x:Name="VerificationGrid" Grid.Row="1" AutoGenerateColumns="False" AlternationCount="2" SelectionMode="Single" IsReadOnly="True" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling">
                                                <DataGrid.Columns>
                                                    <DataGridTextColumn Header="Risorsa" Binding="{Binding Title}" Width="*" MinWidth="190" />
                                                    <DataGridTextColumn Header="Metadati" Binding="{Binding MetadataLabel}" Width="105" />
                                                    <DataGridTextColumn Header="Contenuto" Binding="{Binding ContentLabel}" Width="105" />
                                                    <DataGridTextColumn Header="Cartella" Binding="{Binding DestinationLabel}" Width="105" />
                                                    <DataGridTextColumn Header="ACL" Binding="{Binding AclLabel}" Width="105" />
                                                    <DataGridTextColumn Header="Esito" Binding="{Binding StatusLabel}" Width="115" />
                                                </DataGrid.Columns>
                                            </DataGrid>
                                        </Grid>
                                    </Border>
                                </TabItem>
                                <TabItem Header="Attivit&#xE0; lotto">
                                    <Border Style="{StaticResource Card}" Margin="0" Padding="14,12">
                                        <Grid>
                                            <Grid.RowDefinitions><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /><RowDefinition Height="*" /></Grid.RowDefinitions>
                                            <Grid Grid.Row="0">
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                                                <StackPanel>
                                                    <TextBlock x:Name="BatchPhase" Text="Lotto non avviato" FontSize="14" FontWeight="SemiBold" Foreground="#1D1D1F" />
                                                    <TextBlock x:Name="BatchCurrentOperation" Text="Gli eventi compariranno qui durante l'importazione." Foreground="#66737F" FontSize="11" Margin="0,3,0,0" TextWrapping="Wrap" />
                                                </StackPanel>
                                                <TextBlock x:Name="BatchProgressText" Grid.Column="1" Text="0%" FontSize="20" FontWeight="Bold" Foreground="#007AFF" VerticalAlignment="Center" />
                                            </Grid>
                                            <ProgressBar x:Name="BatchProgressBar" Grid.Row="1" Height="8" Minimum="0" Maximum="100" Value="0" Margin="0,10,0,10" Foreground="#007AFF" Background="#E5E5EA" BorderThickness="0" />
                                            <Grid Grid.Row="2" Margin="0,0,0,10">
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="*" /><ColumnDefinition Width="*" /><ColumnDefinition Width="*" /><ColumnDefinition Width="*" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions>
                                                <StackPanel Grid.Column="0"><TextBlock Text="Completate" Foreground="#66737F" FontSize="10" /><TextBlock x:Name="BatchMetricCompleted" Text="0 / 0" FontWeight="SemiBold" /></StackPanel>
                                                <StackPanel Grid.Column="1"><TextBlock Text="Create" Foreground="#66737F" FontSize="10" /><TextBlock x:Name="BatchMetricCreated" Text="0" FontWeight="SemiBold" /></StackPanel>
                                                <StackPanel Grid.Column="2"><TextBlock Text="Verificate" Foreground="#66737F" FontSize="10" /><TextBlock x:Name="BatchMetricVerified" Text="0" FontWeight="SemiBold" Foreground="#16875D" /></StackPanel>
                                                <StackPanel Grid.Column="3"><TextBlock Text="Errori" Foreground="#66737F" FontSize="10" /><TextBlock x:Name="BatchMetricErrors" Text="0" FontWeight="SemiBold" Foreground="#C9342F" /></StackPanel>
                                                <StackPanel Grid.Column="4"><TextBlock Text="Trascorso" Foreground="#66737F" FontSize="10" /><TextBlock x:Name="BatchElapsed" Text="00:00" FontWeight="SemiBold" /></StackPanel>
                                                <StackPanel Grid.Column="5"><TextBlock Text="Stima residua" Foreground="#66737F" FontSize="10" /><TextBlock x:Name="BatchEta" Text="&#x2014;" FontWeight="SemiBold" /></StackPanel>
                                            </Grid>
                                            <DataGrid x:Name="BatchActivityGrid" Grid.Row="3" AutoGenerateColumns="False" AlternationCount="2" SelectionMode="Single" IsReadOnly="True" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling">
                                                <DataGrid.Columns>
                                                    <DataGridTextColumn Header="Ora" Binding="{Binding Time}" Width="80" />
                                                    <DataGridTextColumn Header="Fase" Binding="{Binding Phase}" Width="145" />
                                                    <DataGridTextColumn Header="Oggetto" Binding="{Binding Object}" Width="155" />
                                                    <DataGridTextColumn Header="Stato" Binding="{Binding Status}" Width="*" MinWidth="260" />
                                                </DataGrid.Columns>
                                            </DataGrid>
                                        </Grid>
                                    </Border>
                                </TabItem>
                            </TabControl>
                            <Border Grid.Row="2" Style="{StaticResource CommandBar}" Margin="0,10,0,0">
                                <Grid>
                                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto" /><ColumnDefinition Width="*" /><ColumnDefinition Width="240" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                                    <Button x:Name="ImportBackButton" Content="&#x2190;  Torna alla revisione" Style="{StaticResource SecondaryButton}" MinHeight="36" Padding="14,7" FontSize="12" />
                                    <TextBlock x:Name="ConfirmationHint" Grid.Column="1" Text="Prima esegui il dry-run." Foreground="#66737F" FontSize="11" VerticalAlignment="Center" Margin="12,0" TextWrapping="Wrap" />
                                    <TextBox x:Name="ImportConfirmation" Grid.Column="2" AutomationProperties.Name="Conferma esatta importazione" IsEnabled="False" ToolTip="Digita la frase di conferma esatta" Margin="4,0" MinHeight="36" Padding="10,7" />
                                    <Button x:Name="ExecuteImportButton" Grid.Column="3" Content="Importa in Passbolt" Style="{StaticResource PrimaryButton}" IsEnabled="False" Margin="8,0,0,0" MinHeight="36" Padding="14,7" FontSize="12" />
                                </Grid>
                            </Border>
                        </Grid>
                    </Grid>
                    <Grid x:Name="RecoveryWorkspace" Visibility="Collapsed">
                        <Grid Margin="6,0,6,6">
                            <Grid.RowDefinitions><RowDefinition Height="Auto" /><RowDefinition Height="*" /><RowDefinition Height="Auto" /></Grid.RowDefinitions>
                            <Border Grid.Row="0" Style="{StaticResource InfoBanner}">
                                <Grid>
                                    <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                                    <StackPanel>
                                        <TextBlock Text="Registri locali di riconciliazione" FontWeight="SemiBold" Foreground="#1D1D1F" />
                                        <TextBlock Text="Seleziona un lotto; l'app lo associa ai candidati riletti dalla cartella corrente prima di qualunque verifica remota." Foreground="#355E85" FontSize="11" TextWrapping="Wrap" />
                                    </StackPanel>
                                    <Button x:Name="RefreshRecoveryButton" Grid.Column="1" Content="Aggiorna lotti" Style="{StaticResource SecondaryButton}" Margin="10,0,0,0" />
                                    <Button x:Name="ArchiveRecoveryButton" Grid.Column="2" Content="Archivia..." Style="{StaticResource SecondaryButton}" Margin="8,0,0,0" IsEnabled="False" />
                                </Grid>
                            </Border>
                            <Grid Grid.Row="1" Margin="0,10,0,0">
                                <Grid.ColumnDefinitions><ColumnDefinition Width="1.15*" /><ColumnDefinition Width="0.85*" /></Grid.ColumnDefinitions>
                                <Border Grid.Column="0" Style="{StaticResource Card}" Margin="0,0,5,0" Padding="0">
                                    <DataGrid x:Name="RecoveryBatchesGrid" AutoGenerateColumns="False" AlternationCount="2" SelectionMode="Single" SelectionUnit="FullRow" IsReadOnly="True" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling">
                                        <DataGrid.Columns>
                                            <DataGridTextColumn Header="Stato" Binding="{Binding StatusLabel}" Width="155" />
                                            <DataGridTextColumn Header="Registrato" Binding="{Binding RecordedAtLabel}" Width="145" />
                                            <DataGridTextColumn Header="Candidati" Binding="{Binding CandidateCountLabel}" Width="80" />
                                            <DataGridTextColumn Header="ID lotto" Binding="{Binding BatchId}" Width="*" MinWidth="200" />
                                        </DataGrid.Columns>
                                    </DataGrid>
                                </Border>
                                <Grid Grid.Column="1" Margin="5,0,0,0">
                                    <Grid.RowDefinitions><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /><RowDefinition Height="*" /></Grid.RowDefinitions>
                                    <Border Grid.Row="0" Style="{StaticResource Card}" Padding="12,9">
                                        <TextBlock x:Name="RecoveryStatus" Text="Aggiorna l'elenco e seleziona un lotto." Foreground="#66737F" FontSize="11" TextWrapping="Wrap" />
                                    </Border>
                                    <Grid Grid.Row="1" Margin="0,8,0,0">
                                        <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="*" /><ColumnDefinition Width="*" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions>
                                        <Border Grid.Column="0" Style="{StaticResource Card}" Margin="0,0,3,0" Padding="9,7"><StackPanel><TextBlock Text="Verificate" Foreground="#66737F" FontSize="10" /><TextBlock x:Name="RecoveryMetricVerified" Text="&#x2014;" FontSize="17" FontWeight="Bold" Foreground="#1F2933" /></StackPanel></Border>
                                        <Border Grid.Column="1" Style="{StaticResource Card}" Margin="3,0" Padding="9,7"><StackPanel><TextBlock Text="Gi&#xE0; riuscite" Foreground="#66737F" FontSize="10" /><TextBlock x:Name="RecoveryMetricRemoteSuccess" Text="&#x2014;" FontSize="17" FontWeight="Bold" Foreground="#16875D" /></StackPanel></Border>
                                        <Border Grid.Column="2" Style="{StaticResource Card}" Margin="3,0" Padding="9,7"><StackPanel><TextBlock Text="Da applicare" Foreground="#66737F" FontSize="10" /><TextBlock x:Name="RecoveryMetricNotApplied" Text="&#x2014;" FontSize="17" FontWeight="Bold" Foreground="#B7791F" /></StackPanel></Border>
                                        <Border Grid.Column="3" Style="{StaticResource Card}" Margin="3,0,0,0" Padding="9,7"><StackPanel><TextBlock Text="Conflitti" Foreground="#66737F" FontSize="10" /><TextBlock x:Name="RecoveryMetricConflicts" Text="&#x2014;" FontSize="17" FontWeight="Bold" Foreground="#C43D4B" /></StackPanel></Border>
                                    </Grid>
                                    <Border Grid.Row="2" Background="#EAF8F0" BorderBrush="#CAEAD8" BorderThickness="1" CornerRadius="12" Padding="11,8" Margin="0,8,0,0">
                                        <TextBlock x:Name="RecoverySafetyStatus" Text="Nessuna cancellazione, spostamento o sovrascrittura viene pianificata dal recupero." Foreground="#248A3D" FontSize="11" TextWrapping="Wrap" />
                                    </Border>
                                </Grid>
                            </Grid>
                            <Border Grid.Row="2" Style="{StaticResource CommandBar}" Margin="0,10,0,0">
                                <Grid>
                                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto" /><ColumnDefinition Width="*" /><ColumnDefinition Width="220" /><ColumnDefinition Width="Auto" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                                    <Button x:Name="RecoveryBackButton" Content="&#x2190;  Torna alla revisione" Style="{StaticResource SecondaryButton}" MinHeight="36" Padding="14,7" FontSize="12" />
                                    <TextBlock x:Name="RecoveryConfirmationHint" Grid.Column="1" Text="Seleziona un lotto recuperabile." Foreground="#66737F" FontSize="11" VerticalAlignment="Center" Margin="12,0" TextWrapping="Wrap" />
                                    <TextBox x:Name="RecoveryConfirmation" Grid.Column="2" AutomationProperties.Name="Conferma esatta recupero" IsEnabled="False" ToolTip="Digita la frase RECUPERA N esatta" Margin="4,0" MinHeight="36" Padding="10,7" />
                                    <Button x:Name="VerifyRecoveryButton" Grid.Column="3" Content="Verifica lotto" Style="{StaticResource SecondaryButton}" IsEnabled="False" Margin="8,0,0,0" MinHeight="36" Padding="14,7" FontSize="12" />
                                    <Button x:Name="ExecuteRecoveryButton" Grid.Column="4" Content="Recupera" Style="{StaticResource PrimaryButton}" IsEnabled="False" Margin="8,0,0,0" MinHeight="36" Padding="14,7" FontSize="12" />
                                </Grid>
                            </Border>
                        </Grid>
                    </Grid>
                        </Grid>
                    </Grid>
                    <Grid x:Name="ExistingAclWorkspace" Visibility="Collapsed">
                        <Grid Margin="6,0,6,6">
                            <Grid.RowDefinitions><RowDefinition Height="Auto" /><RowDefinition Height="*" /><RowDefinition Height="Auto" /></Grid.RowDefinitions>
                            <Border Grid.Row="0" Style="{StaticResource InfoBanner}">
                                <Grid>
                                    <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="150" /><ColumnDefinition Width="240" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                                    <StackPanel>
                                        <TextBlock Text="Permessi degli oggetti esistenti" FontWeight="SemiBold" Foreground="#1D1D1F" />
                                        <TextBlock Text="Consulta, simula e applica una ACL desiderata. Riduzioni e revoche richiedono una conferma rafforzata e il controllo degli utenti effettivamente coinvolti." Foreground="#355E85" FontSize="11" TextWrapping="Wrap" />
                                    </StackPanel>
                                    <ComboBox x:Name="AclTypeFilter" Grid.Column="1" AutomationProperties.Name="Filtro tipo oggetto ACL" Margin="10,0,0,0" SelectedIndex="0" ToolTip="Filtra per tipo di oggetto">
                                        <ComboBoxItem Content="Tutti gli oggetti" Tag="all" />
                                        <ComboBoxItem Content="Solo cartelle" Tag="folder" />
                                        <ComboBoxItem Content="Solo risorse" Tag="resource" />
                                    </ComboBox>
                                    <TextBox x:Name="AclSearchBox" Grid.Column="2" AutomationProperties.Name="Cerca oggetti ACL" Margin="8,0,0,0" ToolTip="Cerca per nome, percorso o ID" />
                                    <Button x:Name="RefreshAclButton" Grid.Column="3" Content="Leggi permessi" Style="{StaticResource SecondaryButton}" Margin="8,0,0,0" IsEnabled="False" />
                                </Grid>
                            </Border>
                            <Grid Grid.Row="1" Margin="0,10,0,0">
                                <Grid.ColumnDefinitions><ColumnDefinition Width="1.05*" /><ColumnDefinition Width="0.95*" /></Grid.ColumnDefinitions>
                                <Border Grid.Column="0" Style="{StaticResource Card}" Margin="0,0,5,0" Padding="0">
                                    <DataGrid x:Name="AclObjectsGrid" AutoGenerateColumns="False" AlternationCount="2" SelectionMode="Single" SelectionUnit="FullRow" IsReadOnly="True" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling">
                                        <DataGrid.Columns>
                                            <DataGridTextColumn Header="Tipo" Binding="{Binding ObjectTypeLabel}" Width="80" />
                                            <DataGridTextColumn Header="Percorso" Binding="{Binding Path}" Width="*" MinWidth="100" />
                                            <DataGridTextColumn Header="Accesso" Binding="{Binding CurrentAccessLabel}" Width="105" />
                                            <DataGridTextColumn Header="Condivisione" Binding="{Binding SharingLabel}" Width="100" />
                                            <DataGridTextColumn Header="ACL" Binding="{Binding StatusLabel}" Width="115" />
                                        </DataGrid.Columns>
                                    </DataGrid>
                                </Border>
                                <Grid Grid.Column="1" Margin="5,0,0,0">
                                    <Grid.RowDefinitions><RowDefinition Height="Auto" /><RowDefinition Height="*" /></Grid.RowDefinitions>
                                    <Border Grid.Row="0" Style="{StaticResource Card}" Padding="12,9">
                                        <TextBlock x:Name="AclObjectSummary" Text="Seleziona un oggetto per visualizzare la relativa ACL." Foreground="#66737F" FontSize="11" TextWrapping="Wrap" />
                                    </Border>
                                    <Border Grid.Row="1" Style="{StaticResource Card}" Margin="0,10,0,0" Padding="0">
                                        <TabControl x:Name="AclDetailTabs" SelectedIndex="0">
                                            <TabItem Header="ACL attuale">
                                                <DataGrid x:Name="AclPermissionsGrid" AutoGenerateColumns="False" AlternationCount="2" SelectionMode="Single" SelectionUnit="FullRow" IsReadOnly="True" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling">
                                                    <DataGrid.Columns>
                                                        <DataGridTextColumn Header="Origine" Binding="{Binding SubjectType}" Width="105" />
                                                        <DataGridTextColumn Header="Soggetto" Binding="{Binding DisplayName}" Width="*" MinWidth="90" />
                                                        <DataGridTextColumn Header="Livello" Binding="{Binding PermissionLabel}" Width="105" />
                                                        <DataGridTextColumn Header="Verifica" Binding="{Binding VerificationLabel}" Width="125" />
                                                        <DataGridTextColumn Header="Dest." Binding="{Binding RecipientCount}" Width="55" />
                                                    </DataGrid.Columns>
                                                </DataGrid>
                                            </TabItem>
                                            <TabItem Header="Piano e applicazione">
                                                <Grid Margin="8">
                                                    <Grid.RowDefinitions><RowDefinition Height="Auto" /><RowDefinition Height="*" /></Grid.RowDefinitions>
                                                    <TextBlock x:Name="AclPlanSummary" Text="Nessun piano calcolato. Seleziona un oggetto verificato di cui sei Proprietario." Foreground="#66737F" FontSize="11" TextWrapping="Wrap" Margin="2,2,2,8" />
                                                    <DataGrid x:Name="AclPlanGrid" Grid.Row="1" AutoGenerateColumns="False" AlternationCount="2" SelectionMode="Single" SelectionUnit="FullRow" IsReadOnly="True" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling">
                                                        <DataGrid.Columns>
                                                            <DataGridTextColumn Header="Azione" Binding="{Binding ActionLabel}" Width="115" />
                                                            <DataGridTextColumn Header="Soggetto" Binding="{Binding DisplayName}" Width="*" MinWidth="60" />
                                                            <DataGridTextColumn Header="Prima" Binding="{Binding BeforeLabel}" Width="105" />
                                                            <DataGridTextColumn Header="Dopo" Binding="{Binding AfterLabel}" Width="105" />
                                                            <DataGridTextColumn Header="Impatto" Binding="{Binding ImpactLabel}" Width="110" />
                                                        </DataGrid.Columns>
                                                    </DataGrid>
                                                </Grid>
                                            </TabItem>
                                        </TabControl>
                                    </Border>
                                </Grid>
                            </Grid>
                            <Border Grid.Row="2" Style="{StaticResource CommandBar}" Margin="0,10,0,0">
                                <Grid>
                                    <Grid.RowDefinitions><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /></Grid.RowDefinitions>
                                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto" /><ColumnDefinition Width="*" /><ColumnDefinition Width="210" /><ColumnDefinition Width="Auto" /><ColumnDefinition Width="Auto" /><ColumnDefinition Width="Auto" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                                    <TextBlock x:Name="AclViewerStatus" Grid.Row="0" Grid.Column="0" Grid.ColumnSpan="2" Text="Avvia la sessione sicura, quindi leggi i permessi esistenti." Foreground="#66737F" FontSize="11" VerticalAlignment="Center" Margin="2,0,10,0" TextWrapping="Wrap" />
                                    <TextBox x:Name="AclConfirmation" Grid.Row="0" Grid.Column="2" Grid.ColumnSpan="5" AutomationProperties.Name="Conferma esatta modifica ACL" HorizontalAlignment="Right" Width="210" IsEnabled="False" ToolTip="Digita la frase di conferma mostrata nel piano" MinHeight="34" Padding="10,6" />
                                    <Button x:Name="AclBackButton" Grid.Row="1" Grid.Column="0" Content="&#x2190;  Torna alla revisione" Style="{StaticResource SecondaryButton}" Margin="0,6,0,0" MinHeight="34" Padding="12,6" FontSize="12" />
                                    <Button x:Name="AclPlanButton" Grid.Row="1" Grid.Column="3" Content="Simula modifica..." Style="{StaticResource SecondaryButton}" IsEnabled="False" Margin="6,6,0,0" MinHeight="34" Padding="11,6" FontSize="12" />
                                    <Button x:Name="ApplyAclButton" Grid.Row="1" Grid.Column="4" Content="Applica ACL" Style="{StaticResource PrimaryButton}" IsEnabled="False" Margin="6,6,0,0" MinHeight="34" Padding="11,6" FontSize="12" />
                                    <Button x:Name="RecoverAclButton" Grid.Row="1" Grid.Column="5" Content="Recupera ACL..." Style="{StaticResource SecondaryButton}" IsEnabled="False" Margin="6,6,0,0" MinHeight="34" Padding="11,6" FontSize="12" />
                                    <Button x:Name="ManageAclJournalsButton" Grid.Row="1" Grid.Column="6" Content="Gestisci journal..." Style="{StaticResource SecondaryButton}" Margin="6,6,0,0" ToolTip="Elenca, filtra, descrive e archivia i journal ACL locali senza cancellarli" MinHeight="34" Padding="11,6" FontSize="12" />
                                </Grid>
                            </Border>
                        </Grid>
                    </Grid>
                </Grid>
            </Grid>
        </Grid>
    </Grid>
</Window>
'@

$Reader = New-Object System.Xml.XmlNodeReader $Xaml
$Window = [Windows.Markup.XamlReader]::Load($Reader)

function Get-Control([string]$Name) {
    $Control = $Window.FindName($Name)
    if ($null -eq $Control) { throw "Controllo UI mancante: $Name" }
    return $Control
}

$ConfigurationPage = Get-Control "ConfigurationPage"
$InventoryPage = Get-Control "InventoryPage"
$ReviewPage = Get-Control "ReviewPage"
$StepConfiguration = Get-Control "StepConfiguration"
$StepConfigurationNumber = Get-Control "StepConfigurationNumber"
$StepConfigurationText = Get-Control "StepConfigurationText"
$StepInventory = Get-Control "StepInventory"
$StepInventoryNumber = Get-Control "StepInventoryNumber"
$StepInventoryText = Get-Control "StepInventoryText"
$StepReview = Get-Control "StepReview"
$StepReviewNumber = Get-Control "StepReviewNumber"
$StepReviewText = Get-Control "StepReviewText"
$StepImport = Get-Control "StepImport"
$StepImportNumber = Get-Control "StepImportNumber"
$StepImportText = Get-Control "StepImportText"
$SafeModeText = Get-Control "SafeModeText"
$PlannedPassboltUrl = Get-Control "PlannedPassboltUrl"
$PassboltUrl = Get-Control "PassboltUrl"
$DetectedFingerprint = Get-Control "DetectedFingerprint"
$VerifyButton = Get-Control "VerifyButton"
$OpenProjectButton = Get-Control "OpenProjectButton"
$ConnectionDot = Get-Control "ConnectionDot"
$ConnectionStatus = Get-Control "ConnectionStatus"
$ClientFolder = Get-Control "ClientFolder"
$BrowseButton = Get-Control "BrowseButton"
$FolderDot = Get-Control "FolderDot"
$FolderStatus = Get-Control "FolderStatus"
$ContinueButton = Get-Control "ContinueButton"
$InventoryRoot = Get-Control "InventoryRoot"
$RefreshButton = Get-Control "RefreshButton"
$ExportButton = Get-Control "ExportButton"
$SourceProfileButton = Get-Control "SourceProfileButton"
$ReviewSelectionButton = Get-Control "ReviewSelectionButton"
$MetricClients = Get-Control "MetricClients"
$MetricFiles = Get-Control "MetricFiles"
$MetricSize = Get-Control "MetricSize"
$MetricIgnored = Get-Control "MetricIgnored"
$ClientFilter = Get-Control "ClientFilter"
$FormatFilter = Get-Control "FormatFilter"
$SearchBox = Get-Control "SearchBox"
$FilterStatus = Get-Control "FilterStatus"
$FilesGrid = Get-Control "FilesGrid"
$WarningsPanel = Get-Control "WarningsPanel"
$WarningsText = Get-Control "WarningsText"
$BackButton = Get-Control "BackButton"
$SaveInventoryProjectButton = Get-Control "SaveInventoryProjectButton"
$SourceFeedbackButton = Get-Control "SourceFeedbackButton"
$ActivityLog = Get-Control "ActivityLog"
$ReviewSummary = Get-Control "ReviewSummary"
$ReviewMetricFiles = Get-Control "ReviewMetricFiles"
$ReviewMetricCandidates = Get-Control "ReviewMetricCandidates"
$ReviewMetricReady = Get-Control "ReviewMetricReady"
$ReviewMetricIncomplete = Get-Control "ReviewMetricIncomplete"
$ReviewPasswordState = Get-Control "ReviewPasswordState"
$ReviewStatusFilter = Get-Control "ReviewStatusFilter"
$ReviewSearchBox = Get-Control "ReviewSearchBox"
$ReviewPasswordToggle = Get-Control "ReviewPasswordToggle"
$EditReviewCandidateButton = Get-Control "EditReviewCandidateButton"
$ReviewFilterStatus = Get-Control "ReviewFilterStatus"
$ReviewCandidatesGrid = Get-Control "ReviewCandidatesGrid"
$ReviewWarningsPanel = Get-Control "ReviewWarningsPanel"
$ReviewWarningsText = Get-Control "ReviewWarningsText"
$ReviewBackButton = Get-Control "ReviewBackButton"
$SaveReviewProjectButton = Get-Control "SaveReviewProjectButton"
$PrepareImportButton = Get-Control "PrepareImportButton"
$ImportPage = Get-Control "ImportPage"
$ImportPageTitle = Get-Control "ImportPageTitle"
$ImportSummary = Get-Control "ImportSummary"
$AclWorkspaceButton = Get-Control "AclWorkspaceButton"
$MigrationWorkspace = Get-Control "MigrationWorkspace"
$NewImportModeButton = Get-Control "NewImportModeButton"
$RecoveryModeButton = Get-Control "RecoveryModeButton"
$NewImportWorkspace = Get-Control "NewImportWorkspace"
$RecoveryWorkspace = Get-Control "RecoveryWorkspace"
$ExistingAclWorkspace = Get-Control "ExistingAclWorkspace"
$ImportWorkspaceTabs = Get-Control "ImportWorkspaceTabs"
$PrivateKeyPath = Get-Control "PrivateKeyPath"
$BrowseKeyButton = Get-Control "BrowseKeyButton"
$KeyPassphrase = Get-Control "KeyPassphrase"
$MfaTotpCode = Get-Control "MfaTotpCode"
$ImportSessionButton = Get-Control "ImportSessionButton"
$Phase04SettingsSeparator = Get-Control "Phase04SettingsSeparator"
$MigrationDestinationPanel = Get-Control "MigrationDestinationPanel"
$AclContextPanel = Get-Control "AclContextPanel"
$DestinationMode = Get-Control "DestinationMode"
$DestinationFolder = Get-Control "DestinationFolder"
$ResourceFormat = Get-Control "ResourceFormat"
$ConfigureClientMappingsButton = Get-Control "ConfigureClientMappingsButton"
$PermissionModeStatus = Get-Control "PermissionModeStatus"
$ConfigurePermissionsButton = Get-Control "ConfigurePermissionsButton"
$DryRunButton = Get-Control "DryRunButton"
$ImportMetricSelected = Get-Control "ImportMetricSelected"
$ImportMetricCreate = Get-Control "ImportMetricCreate"
$ImportMetricDuplicates = Get-Control "ImportMetricDuplicates"
$ImportMetricExisting = Get-Control "ImportMetricExisting"
$ImportIdentity = Get-Control "ImportIdentity"
$ImportPlanGrid = Get-Control "ImportPlanGrid"
$ImportPlanStatus = Get-Control "ImportPlanStatus"
$PreflightStatus = Get-Control "PreflightStatus"
$PreflightGrid = Get-Control "PreflightGrid"
$ExportPreflightReceiptButton = Get-Control "ExportPreflightReceiptButton"
$VerificationStatus = Get-Control "VerificationStatus"
$VerificationGrid = Get-Control "VerificationGrid"
$ExportMigrationReceiptButton = Get-Control "ExportMigrationReceiptButton"
$BatchPhase = Get-Control "BatchPhase"
$BatchCurrentOperation = Get-Control "BatchCurrentOperation"
$BatchProgressText = Get-Control "BatchProgressText"
$BatchProgressBar = Get-Control "BatchProgressBar"
$BatchMetricCompleted = Get-Control "BatchMetricCompleted"
$BatchMetricCreated = Get-Control "BatchMetricCreated"
$BatchMetricVerified = Get-Control "BatchMetricVerified"
$BatchMetricErrors = Get-Control "BatchMetricErrors"
$BatchElapsed = Get-Control "BatchElapsed"
$BatchEta = Get-Control "BatchEta"
$BatchActivityGrid = Get-Control "BatchActivityGrid"
$ImportBackButton = Get-Control "ImportBackButton"
$ConfirmationHint = Get-Control "ConfirmationHint"
$ImportConfirmation = Get-Control "ImportConfirmation"
$ExecuteImportButton = Get-Control "ExecuteImportButton"
$RecoveryBatchesGrid = Get-Control "RecoveryBatchesGrid"
$RefreshRecoveryButton = Get-Control "RefreshRecoveryButton"
$ArchiveRecoveryButton = Get-Control "ArchiveRecoveryButton"
$RecoveryStatus = Get-Control "RecoveryStatus"
$RecoveryMetricVerified = Get-Control "RecoveryMetricVerified"
$RecoveryMetricRemoteSuccess = Get-Control "RecoveryMetricRemoteSuccess"
$RecoveryMetricNotApplied = Get-Control "RecoveryMetricNotApplied"
$RecoveryMetricConflicts = Get-Control "RecoveryMetricConflicts"
$RecoverySafetyStatus = Get-Control "RecoverySafetyStatus"
$RecoveryBackButton = Get-Control "RecoveryBackButton"
$RecoveryConfirmationHint = Get-Control "RecoveryConfirmationHint"
$RecoveryConfirmation = Get-Control "RecoveryConfirmation"
$VerifyRecoveryButton = Get-Control "VerifyRecoveryButton"
$ExecuteRecoveryButton = Get-Control "ExecuteRecoveryButton"
$RefreshAclButton = Get-Control "RefreshAclButton"
$AclTypeFilter = Get-Control "AclTypeFilter"
$AclSearchBox = Get-Control "AclSearchBox"
$AclObjectsGrid = Get-Control "AclObjectsGrid"
$AclObjectSummary = Get-Control "AclObjectSummary"
$AclDetailTabs = Get-Control "AclDetailTabs"
$AclPermissionsGrid = Get-Control "AclPermissionsGrid"
$AclPlanSummary = Get-Control "AclPlanSummary"
$AclPlanGrid = Get-Control "AclPlanGrid"
$AclViewerStatus = Get-Control "AclViewerStatus"
$AclPlanButton = Get-Control "AclPlanButton"
$AclConfirmation = Get-Control "AclConfirmation"
$ApplyAclButton = Get-Control "ApplyAclButton"
$RecoverAclButton = Get-Control "RecoverAclButton"
$ManageAclJournalsButton = Get-Control "ManageAclJournalsButton"
$AclBackButton = Get-Control "AclBackButton"

$script:ConnectionVerified = $false
$script:VerifiedUrl = ""
$script:VerifiedFingerprint = ""
$script:Phase04Workspace = "new_import"
$script:LastMigrationWorkspace = "new_import"
$script:SynchronizingPassboltUrl = $false
$script:InventoryResult = $null
$script:InventoryFolder = ""
$script:AllInventoryRows = @()
$script:ReviewResult = $null
$script:AllReviewRows = @()
$script:ReviewedSourceFiles = @()
$script:ReviewFilePasswords = @{}
$script:SourceMappingProfile = $null
$script:PendingProjectSourceRoot = ""
$script:PendingProjectSelectedFiles = @()
$script:PendingProjectSelectedCandidates = @()
$script:LoadedProjectDigest = ""
$script:ReviewPasswordsVisible = $false
$script:UpdatingReviewPasswordToggle = $false
$script:ImportCandidates = @()
$script:ImportSecretOverrides = @{}
$script:ImportSourceFilePasswords = @{}
$script:ImportPlan = $null
$script:ImportPlanKeyPath = ""
$script:PreflightReceiptEvidence = $null
$script:MigrationReceiptEvidence = $null
$script:ImportCompleted = $false
$script:ImportDashboard = $null
$script:ImportSessionProcess = $null
$script:ImportSessionErrorTask = $null
$script:ImportSessionId = ""
$script:ImportSessionInfo = $null
$script:ImportSessionLastActivityUtc = [DateTime]::MinValue
$script:ImportSessionRoot = ""
$script:ImportSessionKeyPath = ""
$script:ImportSessionIdleTimeoutMinutes = 30
$script:RecoveryBatches = @()
$script:RecoveryBatchDetails = $null
$script:RecoveryCandidates = @()
$script:RecoverySecretOverrides = @{}
$script:RecoverySourceFilePasswords = @{}
$script:RecoveryPlan = $null
$script:UpdatingRecoverySelection = $false
$script:ImportRecoveryRequired = $false
$script:ClosingApplication = $false
$script:PopulatingDestinationFolders = $false
$script:AvailableDestinationFolders = @()
$script:DestinationFolderCatalogLoaded = $false
$script:ClientDestinationMap = @{}
$script:PermissionMode = "inherited"
$script:PermissionTemplate = @()
$script:PermissionCatalog = @()
$script:PermissionCatalogSessionId = ""
$script:AclCatalogSessionId = ""
$script:AllAclObjectRows = @()
$script:UpdatingAclSelection = $false
$script:AclPlan = $null
$script:AclRecoveryRequired = $false
$script:AclRecoveryBlockingCount = 0
$script:CurrentPage = "Configuration"
$script:OperationalState = [pscustomobject]@{
    Mode = "Idle"
    OperationId = ""
    Name = ""
    Category = ""
    StartedAtUtc = [DateTime]::MinValue
    Active = $null
}
$script:OperationPollTimer = $null

function Get-Brush([string]$Color) {
    return [Windows.Media.BrushConverter]::new().ConvertFromString($Color)
}

function Initialize-ModernDialog([System.Windows.Window]$Dialog) {
    $Dialog.Background = Get-Brush "#F5F5F7"
    $Dialog.FontFamily = $Window.FontFamily
    $Dialog.UseLayoutRounding = $true
    $Dialog.SnapsToDevicePixels = $true
    $Dialog.Resources.MergedDictionaries.Add($Window.Resources)
}

function Add-Activity([string]$Message) {
    $Timestamp = Get-Date -Format "HH:mm:ss"
    if ($ActivityLog.Text) { $ActivityLog.AppendText([Environment]::NewLine) }
    $ActivityLog.AppendText("[$Timestamp] $Message")
    $ActivityLog.ScrollToEnd()
}

function Test-OperationActive {
    return [string]$script:OperationalState.Mode -eq "Running"
}

function Update-OperationalControlState {
    $Interactive = -not (Test-OperationActive) -and [string]$script:OperationalState.Mode -ne "Closing"
    if ($null -ne $Window.Content) {
        $Window.Content.IsEnabled = $Interactive
    }
}

function Set-InteractiveSurfaceEnabled([object]$Surface, [bool]$Enabled) {
    if ($null -eq $Surface) { return }
    try {
        if ($Surface.PSObject.Properties.Name -contains "IsEnabled") { $Surface.IsEnabled = $Enabled }
        elseif ($Surface.PSObject.Properties.Name -contains "Enabled") { $Surface.Enabled = $Enabled }
    } catch {}
}

function Enter-OperationalState(
    [string]$Name,
    [ValidateSet("read", "verify", "write", "recover")][string]$Category,
    [string]$OperationId = ([guid]::NewGuid().ToString("N"))
) {
    if ([string]$script:OperationalState.Mode -ne "Idle") { return $null }
    $script:OperationalState.Mode = "Running"
    $script:OperationalState.OperationId = $OperationId
    $script:OperationalState.Name = $Name
    $script:OperationalState.Category = $Category
    $script:OperationalState.StartedAtUtc = [DateTime]::UtcNow
    $script:OperationalState.Active = $null
    Update-OperationalControlState
    return $OperationId
}

function Exit-OperationalState([string]$OperationId) {
    if (
        [string]$script:OperationalState.Mode -ne "Running" -or
        [string]$script:OperationalState.OperationId -ne $OperationId
    ) { return $false }
    $script:OperationalState.Mode = "Idle"
    $script:OperationalState.OperationId = ""
    $script:OperationalState.Name = ""
    $script:OperationalState.Category = ""
    $script:OperationalState.StartedAtUtc = [DateTime]::MinValue
    $script:OperationalState.Active = $null
    Update-OperationalControlState
    return $true
}

function Clear-OperationalSensitivePayload([object]$Payload) {
    if ($null -eq $Payload -or $null -eq $Payload.InputObject) { return }
    foreach ($PropertyName in @("secret_overrides", "source_file_passwords", "file_passwords")) {
        if ($Payload.InputObject.PSObject.Properties.Name -contains $PropertyName) {
            foreach ($Entry in @($Payload.InputObject.$PropertyName)) {
                if ($null -ne $Entry -and $Entry.PSObject.Properties.Name -contains "password") { $Entry.password = $null }
            }
        }
    }
    foreach ($PropertyName in @("passphrase", "mfa_totp", "secret_overrides", "source_file_passwords", "file_passwords", "ciphertext", "project_json", "envelope_json", "project")) {
        if ($Payload.InputObject.PSObject.Properties.Name -contains $PropertyName) {
            $Payload.InputObject.$PropertyName = $null
        }
    }
}

$script:OperationWorkerScript = {
    param(
        [string]$WorkKind,
        [object]$Payload,
        [System.Collections.Concurrent.ConcurrentQueue[object]]$ProgressQueue
    )

    function ConvertTo-WorkerProcessArgument([string]$Value) {
        if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
        if ($Value -notmatch '[\s"]') { return $Value }
        $Builder = New-Object System.Text.StringBuilder
        [void]$Builder.Append('"')
        $Backslashes = 0
        foreach ($Character in $Value.ToCharArray()) {
            if ($Character -eq '\') {
                $Backslashes++
                continue
            }
            if ($Character -eq '"') {
                [void]$Builder.Append(('\' * (($Backslashes * 2) + 1)))
                [void]$Builder.Append('"')
                $Backslashes = 0
                continue
            }
            if ($Backslashes -gt 0) {
                [void]$Builder.Append(('\' * $Backslashes))
                $Backslashes = 0
            }
            [void]$Builder.Append($Character)
        }
        if ($Backslashes -gt 0) { [void]$Builder.Append(('\' * ($Backslashes * 2))) }
        [void]$Builder.Append('"')
        return $Builder.ToString()
    }

    function Invoke-WorkerPythonJson([object]$Request) {
        $StartInfo = New-Object System.Diagnostics.ProcessStartInfo
        $StartInfo.FileName = [string]$Request.Executable
        $ProcessArguments = @([string]$Request.Script) + @($Request.Arguments)
        $StartInfo.Arguments = (@($ProcessArguments | ForEach-Object { ConvertTo-WorkerProcessArgument ([string]$_) }) -join ' ')
        $StartInfo.WorkingDirectory = [string]$Request.WorkingDirectory
        $StartInfo.UseShellExecute = $false
        $StartInfo.CreateNoWindow = $true
        $StartInfo.RedirectStandardOutput = $true
        $StartInfo.RedirectStandardError = $true
        $StartInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $StartInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
        $Process = New-Object System.Diagnostics.Process
        $Process.StartInfo = $StartInfo
        try {
            if (-not $Process.Start()) { throw "Impossibile avviare la procedura Python locale." }
            $OutputTask = $Process.StandardOutput.ReadToEndAsync()
            $ErrorTask = $Process.StandardError.ReadToEndAsync()
            if (-not $Process.WaitForExit([int]$Request.TimeoutMilliseconds)) {
                try { $Process.Kill() } catch {}
                throw "Timeout della procedura Python locale."
            }
            $Text = $OutputTask.Result
            $ErrorText = $ErrorTask.Result
            if ($Process.ExitCode -ne 0) {
                if ([string]::IsNullOrWhiteSpace($ErrorText)) { throw $Text }
                throw $ErrorText
            }
            if ([string]::IsNullOrWhiteSpace($Text)) { throw "La procedura Python locale non ha restituito un risultato valido." }
            return $Text | ConvertFrom-Json
        } finally {
            if ($null -ne $Process) { $Process.Dispose() }
        }
    }

    function Invoke-WorkerSecureJsonProcess([object]$Request) {
        $StartInfo = New-Object System.Diagnostics.ProcessStartInfo
        $StartInfo.FileName = [string]$Request.Executable
        $StartInfo.Arguments = (@($Request.Arguments | ForEach-Object { ConvertTo-WorkerProcessArgument ([string]$_) }) -join ' ')
        $StartInfo.WorkingDirectory = [string]$Request.WorkingDirectory
        $StartInfo.UseShellExecute = $false
        $StartInfo.CreateNoWindow = $true
        $StartInfo.RedirectStandardInput = $true
        $StartInfo.RedirectStandardOutput = $true
        $StartInfo.RedirectStandardError = $true
        $StartInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $StartInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
        $Process = New-Object System.Diagnostics.Process
        $Process.StartInfo = $StartInfo
        $JsonPayload = $Request.InputObject | ConvertTo-Json -Depth 14 -Compress
        $PayloadBytes = $null
        try {
            if (-not $Process.Start()) { throw "Impossibile avviare la procedura locale protetta." }
            $OutputTask = $Process.StandardOutput.ReadToEndAsync()
            $ErrorTask = $Process.StandardError.ReadToEndAsync()
            $PayloadBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($JsonPayload)
            $Process.StandardInput.BaseStream.Write($PayloadBytes, 0, $PayloadBytes.Length)
            $Process.StandardInput.BaseStream.Flush()
            $Process.StandardInput.Close()
            $JsonPayload = $null
            $PayloadBytes = $null
            if (-not $Process.WaitForExit([int]$Request.TimeoutMilliseconds)) {
                try { $Process.Kill() } catch {}
                throw "Timeout della procedura locale protetta."
            }
            $OutputText = $OutputTask.Result
            $IgnoredErrorOutput = $ErrorTask.Result
            if ([string]::IsNullOrWhiteSpace($OutputText)) {
                throw "La procedura locale protetta non ha restituito un risultato valido."
            }
            try { $Envelope = $OutputText | ConvertFrom-Json }
            catch { throw "La procedura locale protetta ha restituito dati non validi." }
            if ($null -eq $Envelope -or -not ($Envelope.PSObject.Properties.Name -contains "ok")) {
                throw "La procedura locale protetta ha restituito una struttura inattesa."
            }
            return $Envelope
        } finally {
            $JsonPayload = $null
            $PayloadBytes = $null
            if ($null -ne $Process) { $Process.Dispose() }
        }
    }

    function Invoke-WorkerImportSessionJson([object]$Request) {
        $Process = $Request.Process
        if ($null -eq $Process) { throw "Il coordinatore della sessione sicura non e' disponibile." }
        try {
            if ($Process.HasExited) { throw "La sessione sicura locale si e' chiusa inaspettatamente." }
        } catch {
            throw "La sessione sicura locale non e' piu disponibile."
        }
        $JsonPayload = $Request.InputObject | ConvertTo-Json -Depth 14 -Compress
        if ($JsonPayload.Length -gt 67108864) { throw "La richiesta della sessione sicura e' troppo grande." }
        $PayloadBytes = $null
        try {
            $PayloadBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($JsonPayload + "`n")
            $Process.StandardInput.BaseStream.Write($PayloadBytes, 0, $PayloadBytes.Length)
            $Process.StandardInput.BaseStream.Flush()
            $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            while ($true) {
                $Remaining = [int]$Request.TimeoutMilliseconds - [int]$Stopwatch.ElapsedMilliseconds
                if ($Remaining -le 0) {
                    try { $Process.Kill() } catch {}
                    throw "Timeout della sessione sicura locale."
                }
                $OutputTask = $Process.StandardOutput.ReadLineAsync()
                if (-not $OutputTask.Wait($Remaining)) {
                    try { $Process.Kill() } catch {}
                    throw "Timeout della sessione sicura locale."
                }
                $OutputText = $OutputTask.Result
                if ([string]::IsNullOrWhiteSpace($OutputText) -or $OutputText.Length -gt 67108864) {
                    throw "La sessione sicura locale non ha restituito un risultato valido."
                }
                try { $Envelope = $OutputText | ConvertFrom-Json }
                catch { throw "La sessione sicura locale ha restituito dati non validi." }
                if ($null -ne $Envelope -and [string]$Envelope.type -eq "progress") {
                    if ($null -eq $ProgressQueue) { throw "La sessione sicura locale ha restituito un avanzamento inatteso." }
                    $ProgressQueue.Enqueue($Envelope)
                    continue
                }
                if ($null -eq $Envelope -or -not ($Envelope.PSObject.Properties.Name -contains "ok")) {
                    throw "La sessione sicura locale ha restituito una struttura inattesa."
                }
                return $Envelope
            }
        } catch {
            try {
                if ($null -ne $Process -and -not $Process.HasExited) { $Process.Kill() }
            } catch {}
            throw
        } finally {
            $JsonPayload = $null
            $PayloadBytes = $null
        }
    }

    switch ($WorkKind) {
        "PythonJson" { return Invoke-WorkerPythonJson $Payload }
        "SecureJsonProcess" { return Invoke-WorkerSecureJsonProcess $Payload }
        "ImportSessionJson" { return Invoke-WorkerImportSessionJson $Payload }
        default { throw "Tipo di lavoro asincrono non supportato: $WorkKind" }
    }
}

function New-PythonJsonOperationPayload([string]$Script, [string[]]$Arguments, [int]$TimeoutMilliseconds = 180000) {
    return [pscustomobject]@{
        Executable = $PythonExecutable
        Script = $Script
        Arguments = @($Arguments)
        TimeoutMilliseconds = $TimeoutMilliseconds
        WorkingDirectory = $ProjectRoot
    }
}

function New-SecureJsonOperationPayload(
    [string]$Executable,
    [string[]]$Arguments,
    [object]$InputObject,
    [int]$TimeoutMilliseconds = 180000
) {
    return [pscustomobject]@{
        Executable = $Executable
        Arguments = @($Arguments)
        InputObject = $InputObject
        TimeoutMilliseconds = $TimeoutMilliseconds
        WorkingDirectory = $ProjectRoot
    }
}

function New-ImportSessionOperationPayload([object]$InputObject, [int]$TimeoutMilliseconds = 180000) {
    return [pscustomobject]@{
        Process = $script:ImportSessionProcess
        InputObject = $InputObject
        TimeoutMilliseconds = $TimeoutMilliseconds
    }
}

function Drain-OperationProgress([object]$Operation) {
    if ($null -eq $Operation -or $null -eq $Operation.ProgressQueue) { return }
    $ProgressEnvelope = $null
    while ($Operation.ProgressQueue.TryDequeue([ref]$ProgressEnvelope)) {
        $script:ImportSessionLastActivityUtc = [DateTime]::UtcNow
        if ($null -ne $Operation.OnProgress) {
            try { & $Operation.OnProgress $ProgressEnvelope $Operation }
            catch { Add-Activity "Aggiornamento del progresso non riuscito: $($_.Exception.Message)" }
        }
        $ProgressEnvelope = $null
    }
}

function Complete-UiOperation([string]$OperationId) {
    if (-not (Test-OperationActive)) { return }
    $Operation = $script:OperationalState.Active
    if ($null -eq $Operation -or [string]$Operation.OperationId -ne $OperationId -or -not $Operation.AsyncResult.IsCompleted) { return }
    Drain-OperationProgress $Operation
    $Succeeded = $false
    $Result = $null
    $FailureMessage = ""
    try {
        $Output = $Operation.PowerShell.EndInvoke($Operation.AsyncResult)
        if ($null -ne $Output -and $Output.Count -gt 0) { $Result = $Output[$Output.Count - 1] }
        $Succeeded = $true
        $script:ImportSessionLastActivityUtc = [DateTime]::UtcNow
    } catch {
        $FailureMessage = [string]$_.Exception.Message
        if (-not $FailureMessage -and $Operation.PowerShell.Streams.Error.Count -gt 0) {
            $FailureMessage = [string]$Operation.PowerShell.Streams.Error[0].Exception.Message
        }
        if (-not $FailureMessage) { $FailureMessage = "Operazione non completata." }
    } finally {
        Clear-OperationalSensitivePayload $Operation.Payload
        $Operation.PowerShell.Dispose()
        [void](Exit-OperationalState $OperationId)
        Set-InteractiveSurfaceEnabled $Operation.InteractiveSurface $true
    }
    try {
        if ($Succeeded) {
            if ($null -ne $Operation.OnSuccess) { & $Operation.OnSuccess $Result $Operation }
        } elseif ($null -ne $Operation.OnFailure) {
            & $Operation.OnFailure $FailureMessage $Operation
        } else {
            Add-Activity "$($Operation.Name) non completata: $FailureMessage"
        }
    } catch {
        Add-Activity "Cleanup UI dell'operazione '$($Operation.Name)' non completato: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Operazione non completata", "OK", "Error") | Out-Null
    } finally {
        if ($null -ne $Operation.OnFinally) {
            try { & $Operation.OnFinally $Operation } catch { Add-Activity "Cleanup finale non completato: $($_.Exception.Message)" }
        }
    }
}

function Start-UiOperation(
    [string]$Name,
    [ValidateSet("read", "verify", "write", "recover")][string]$Category,
    [ValidateSet("PythonJson", "SecureJsonProcess", "ImportSessionJson")][string]$WorkKind,
    [object]$Payload,
    [scriptblock]$OnSuccess = $null,
    [scriptblock]$OnFailure = $null,
    [scriptblock]$OnFinally = $null,
    [scriptblock]$OnProgress = $null,
    [object]$Context = $null,
    [object]$InteractiveSurface = $null
) {
    $OperationId = Enter-OperationalState $Name $Category
    if (-not $OperationId) {
        Add-Activity "Richiesta ignorata: e' gia' in corso l'operazione '$($script:OperationalState.Name)'."
        return $false
    }
    $PowerShell = $null
    try {
        $PowerShell = [PowerShell]::Create()
        $ProgressQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $Operation = [pscustomobject]@{
            OperationId = $OperationId
            Name = $Name
            Category = $Category
            WorkKind = $WorkKind
            Payload = $Payload
            Context = $Context
            ProgressQueue = $ProgressQueue
            OnSuccess = $OnSuccess
            OnFailure = $OnFailure
            OnFinally = $OnFinally
            OnProgress = $OnProgress
            InteractiveSurface = $InteractiveSurface
            PowerShell = $PowerShell
            AsyncResult = $null
        }
        [void]$PowerShell.AddScript($script:OperationWorkerScript.ToString()).AddArgument($WorkKind).AddArgument($Payload).AddArgument($ProgressQueue)
        $Operation.AsyncResult = $PowerShell.BeginInvoke()
        $script:OperationalState.Active = $Operation
        Set-InteractiveSurfaceEnabled $InteractiveSurface $false
        return $true
    } catch {
        Clear-OperationalSensitivePayload $Payload
        if ($null -ne $PowerShell) { $PowerShell.Dispose() }
        [void](Exit-OperationalState $OperationId)
        throw
    }
}

function Format-Size([long]$Bytes) {
    $Size = [double]$Bytes
    foreach ($Unit in @("B", "KB", "MB", "GB", "TB")) {
        if ($Size -lt 1024 -or $Unit -eq "TB") {
            if ($Unit -eq "B") { return "{0:N0} {1}" -f $Size, $Unit }
            return "{0:N1} {1}" -f $Size, $Unit
        }
        $Size /= 1024
    }
}

function ConvertTo-FeedbackIssuePayload([object[]]$Issues) {
    $Result = New-Object System.Collections.Generic.List[object]
    foreach ($Issue in @($Issues)) {
        if ($null -eq $Issue) { continue }
        $Result.Add([pscustomobject][ordered]@{
            reason_code = [string]$Issue.reason_code
            extension = [string]$Issue.extension
            count = [int64]$Issue.count
        })
    }
    return $Result.ToArray()
}

function Get-SourceFeedbackRequest {
    if ($null -eq $script:InventoryResult) { return $null }
    $Review = $null
    if ($null -ne $script:ReviewResult) {
        $Review = [pscustomobject][ordered]@{
            selected_files = [int64]$script:ReviewResult.selected_files
            analyzed_files = [int64]$script:ReviewResult.analyzed_files
            candidate_count = [int64]$script:ReviewResult.candidate_count
            ready_count = [int64]$script:ReviewResult.ready_count
            incomplete_count = [int64]$script:ReviewResult.incomplete_count
            issues = @(ConvertTo-FeedbackIssuePayload @($script:ReviewResult.issues))
        }
    }
    return [pscustomobject][ordered]@{
        command = "source-summary"
        inventory = [pscustomobject][ordered]@{
            supported_files = [int64]$script:InventoryResult.supported_files
            ignored_files = [int64]$script:InventoryResult.ignored_files
            issues = @(ConvertTo-FeedbackIssuePayload @($script:InventoryResult.issues))
        }
        review = $Review
    }
}

function Update-SourceFeedbackState {
    if ($null -eq $script:InventoryResult) {
        $SourceFeedbackButton.Content = "Esclusioni e conversioni"
        $SourceFeedbackButton.IsEnabled = $false
        return
    }
    $IssueCount = 0L
    foreach ($Issue in @($script:InventoryResult.issues)) { $IssueCount += [int64]$Issue.count }
    if ($null -ne $script:ReviewResult) {
        foreach ($Issue in @($script:ReviewResult.issues)) { $IssueCount += [int64]$Issue.count }
    }
    $SourceFeedbackButton.Content = "Esclusioni e conversioni ($IssueCount)"
    $SourceFeedbackButton.IsEnabled = $true
}

function Show-SourceFeedbackResult([object]$Result) {
    $Lines = New-Object System.Collections.Generic.List[string]
    $Lines.Add("Il riepilogo contiene soltanto conteggi aggregati; nomi, clienti e percorsi sono esclusi.")
    $Lines.Add("")
    $Sections = @(
        [pscustomobject]@{ Title = "Inventario completo"; Groups = @($Result.inventory_groups) },
        [pscustomobject]@{ Title = "Ultima revisione selezionata"; Groups = @($Result.review_groups) }
    )
    foreach ($Section in $Sections) {
        $Lines.Add("$($Section.Title):")
        if (@($Section.Groups).Count -eq 0) {
            $Lines.Add("  Nessuna segnalazione disponibile.")
            $Lines.Add("")
            continue
        }
        foreach ($Group in @($Section.Groups)) {
            $Formats = @($Group.by_format | Select-Object -First 12 | ForEach-Object { "$([string]$_.format): $([int64]$_.count)" })
            if (@($Group.by_format).Count -gt 12) { $Formats += "altri formati aggregati" }
            $Lines.Add("  $([int64]$Group.count) - $([string]$Group.label) [$($Formats -join ', ')]")
            $Lines.Add("    Azione: $([string]$Group.action)")
        }
        $Lines.Add("")
    }
    if ($null -ne $Result.coverage.PSObject.Properties["review_incomplete_count"]) {
        $Lines.Add("Candidati incompleti nell'ultima revisione: $([int64]$Result.coverage.review_incomplete_count)")
    } else {
        $Lines.Add("Ultima revisione: non ancora disponibile.")
    }
    [System.Windows.MessageBox]::Show(
        ($Lines -join [Environment]::NewLine),
        "Esclusioni e conversioni",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Information
    ) | Out-Null
}

function Invoke-SourceFeedback {
    $Request = Get-SourceFeedbackRequest
    if ($null -eq $Request) { return }
    [void](Start-UiOperation "Riepilogo esclusioni e conversioni" "read" "SecureJsonProcess" `
        (New-SecureJsonOperationPayload $PythonExecutable @($ReceiptScript, "--secure-json") $Request 30000) `
        -OnSuccess {
            param($Envelope, $Operation)
            if (-not [bool]$Envelope.ok) {
                $Message = Get-SecureErrorMessage $Envelope
                Add-Activity "Riepilogo sorgenti rifiutato: $Message"
                [System.Windows.MessageBox]::Show($Message, "Riepilogo non disponibile", "OK", "Error") | Out-Null
                return
            }
            Show-SourceFeedbackResult $Envelope.result
            Add-Activity "Riepilogo sorgenti mostrato: soli conteggi aggregati, senza nomi o percorsi."
        } `
        -OnFailure {
            param($FailureMessage, $Operation)
            Add-Activity "Riepilogo sorgenti non disponibile: $FailureMessage"
            [System.Windows.MessageBox]::Show($FailureMessage, "Riepilogo non disponibile", "OK", "Error") | Out-Null
        })
}

function New-PreflightReceiptEvidence([object]$Plan) {
    $Checks = New-Object System.Collections.Generic.List[object]
    foreach ($Check in @($Plan.preflight_checks)) {
        $Checks.Add([pscustomobject][ordered]@{
            id = [string]$Check.id
            status = [string]$Check.status
        })
    }
    $ResourceFormat = [string]$Plan.resource_format_selected
    if ([string]::IsNullOrWhiteSpace($ResourceFormat)) { $ResourceFormat = "unavailable" }
    $FolderFormat = [string]$Plan.folder_format_selected
    if ([string]::IsNullOrWhiteSpace($FolderFormat)) {
        $FolderFormat = if ([string]$Plan.destination_mode -eq "client_folders") { "unavailable" } else { "not_required" }
    }
    return [pscustomobject][ordered]@{
        plan_digest = [string]$Plan.plan_digest
        status = [string]$Plan.preflight_status
        destination_mode = [string]$Plan.destination_mode
        resource_format = $ResourceFormat
        folder_format = $FolderFormat
        permission_mode = [string]$Plan.permission_mode
        permission_entry_count = [int64]$Plan.permission_template_entry_count
        selected_count = [int64]$script:ImportCandidates.Count
        create_count = [int64]$Plan.create_count
        duplicate_count = [int64]$Plan.duplicate_count
        blocked_count = [int64]$Plan.blocked_count
        create_folder_count = [int64]$Plan.create_folder_count
        create_shared_folder_count = [int64]$Plan.create_shared_folder_count
        reconcile_shared_folder_count = [int64]$Plan.reconcile_shared_folder_count
        reuse_folder_count = [int64]$Plan.reuse_folder_count
        shared_create_count = [int64]$Plan.shared_create_count
        encrypted_secret_copy_count = [int64]$Plan.encrypted_secret_copy_count
        required_client_count = [int64]@($Plan.required_clients).Count
        mapped_client_count = [int64]@($Plan.client_destination_mapping).Count
        checks = $Checks.ToArray()
    }
}

function New-MigrationReceiptEvidence([object]$Result, [object]$PreflightEvidence) {
    return [pscustomobject][ordered]@{
        plan_digest = [string]$PreflightEvidence.plan_digest
        destination_mode = [string]$PreflightEvidence.destination_mode
        resource_format = [string]$PreflightEvidence.resource_format
        folder_format = [string]$PreflightEvidence.folder_format
        permission_mode = [string]$PreflightEvidence.permission_mode
        permission_entry_count = [int64]$PreflightEvidence.permission_entry_count
        selected_count = [int64]$PreflightEvidence.selected_count
        planned_create_count = [int64]$PreflightEvidence.create_count
        created_count = [int64]$Result.created_count
        shared_created_count = [int64]$Result.shared_created_count
        encrypted_secret_copy_count = [int64]$Result.encrypted_secret_copy_count
        skipped_duplicate_count = [int64]$Result.skipped_duplicate_count
        created_folder_count = [int64]$Result.created_folder_count
        shared_created_folder_count = [int64]$Result.shared_created_folder_count
        reconciled_shared_folder_count = [int64]$Result.reconciled_shared_folder_count
        reused_folder_count = [int64]$Result.reused_folder_count
        verified_resource_count = [int64]$Result.verified_resource_count
        verification_failed_count = [int64]$Result.verification_failed_count
        journal_batch_id = [string]$Result.reconciliation_batch_id
        journal_status = [string]$Result.reconciliation_status
        complete = [bool]$Result.complete
    }
}

function Export-MigrationReceipt([ValidateSet("preflight", "migration")][string]$ReceiptType) {
    $Evidence = if ($ReceiptType -eq "preflight") { $script:PreflightReceiptEvidence } else { $script:MigrationReceiptEvidence }
    if ($null -eq $Evidence) { return }
    $Dialog = New-Object System.Windows.Forms.SaveFileDialog
    $Dialog.Filter = "Ricevuta JSON (*.json)|*.json"
    $Dialog.DefaultExt = "json"
    $Dialog.AddExtension = $true
    $Dialog.OverwritePrompt = $true
    $Prefix = if ($ReceiptType -eq "preflight") { "passbolt-preflight" } else { "passbolt-migrazione" }
    $Dialog.FileName = "$Prefix-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
    if ($Dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $Request = [pscustomobject][ordered]@{
        command = "write-receipt"
        receipt_type = $ReceiptType
        evidence = $Evidence
        destination = [string]$Dialog.FileName
    }
    [void](Start-UiOperation "Esportazione ricevuta $ReceiptType" "read" "SecureJsonProcess" `
        (New-SecureJsonOperationPayload $PythonExecutable @($ReceiptScript, "--secure-json") $Request 30000) `
        -OnSuccess {
            param($Envelope, $Operation)
            if (-not [bool]$Envelope.ok) {
                $Message = Get-SecureErrorMessage $Envelope
                Add-Activity "Esportazione ricevuta rifiutata: $Message"
                [System.Windows.MessageBox]::Show($Message, "Ricevuta non esportata", "OK", "Error") | Out-Null
                return
            }
            $DigestPrefix = ([string]$Envelope.result.receipt_digest).Substring(0, 12).ToUpperInvariant()
            Add-Activity "Ricevuta $([string]$Envelope.result.receipt_type) esportata con digest $DigestPrefix; nessun dato sorgente o segreto incluso."
            [System.Windows.MessageBox]::Show(
                "Ricevuta esportata correttamente.`n`nDigest: $DigestPrefix...`n`nIl file contiene soltanto evidenze tecniche aggregate e sanitizzate.",
                "Ricevuta esportata",
                "OK",
                "Information"
            ) | Out-Null
        } `
        -OnFailure {
            param($FailureMessage, $Operation)
            Add-Activity "Esportazione ricevuta non riuscita: $FailureMessage"
            [System.Windows.MessageBox]::Show($FailureMessage, "Ricevuta non esportata", "OK", "Error") | Out-Null
        })
}

function Invoke-PythonJson([string]$Script, [string[]]$Arguments) {
    $Output = & $PythonExecutable $Script @Arguments 2>&1
    $ExitCode = $LASTEXITCODE
    $Text = ($Output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    if ($ExitCode -ne 0) { throw $Text }
    return $Text | ConvertFrom-Json
}

function ConvertTo-ProcessArgument([string]$Value) {
    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $Builder = New-Object System.Text.StringBuilder
    [void]$Builder.Append('"')
    $Backslashes = 0
    foreach ($Character in $Value.ToCharArray()) {
        if ($Character -eq '\') {
            $Backslashes++
            continue
        }
        if ($Character -eq '"') {
            [void]$Builder.Append(('\' * (($Backslashes * 2) + 1)))
            [void]$Builder.Append('"')
            $Backslashes = 0
            continue
        }
        if ($Backslashes -gt 0) {
            [void]$Builder.Append(('\' * $Backslashes))
            $Backslashes = 0
        }
        [void]$Builder.Append($Character)
    }
    if ($Backslashes -gt 0) { [void]$Builder.Append(('\' * ($Backslashes * 2))) }
    [void]$Builder.Append('"')
    return $Builder.ToString()
}

function Invoke-SecureJsonProcess(
    [string]$Executable,
    [string[]]$Arguments,
    [object]$InputObject,
    [int]$TimeoutMilliseconds = 180000
) {
    $StartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $StartInfo.FileName = $Executable
    $QuotedArguments = @($Arguments | ForEach-Object { ConvertTo-ProcessArgument ([string]$_) })
    $StartInfo.Arguments = $QuotedArguments -join ' '
    $StartInfo.UseShellExecute = $false
    $StartInfo.CreateNoWindow = $true
    $StartInfo.RedirectStandardInput = $true
    $StartInfo.RedirectStandardOutput = $true
    $StartInfo.RedirectStandardError = $true
    $StartInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $StartInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)

    $Process = New-Object System.Diagnostics.Process
    $Process.StartInfo = $StartInfo
    $Payload = $InputObject | ConvertTo-Json -Depth 14 -Compress
    try {
        if (-not $Process.Start()) { throw "Impossibile avviare la procedura locale protetta." }
        $OutputTask = $Process.StandardOutput.ReadToEndAsync()
        $ErrorTask = $Process.StandardError.ReadToEndAsync()
        $PayloadBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Payload)
        $Process.StandardInput.BaseStream.Write($PayloadBytes, 0, $PayloadBytes.Length)
        $Process.StandardInput.BaseStream.Flush()
        $Process.StandardInput.Close()
        $PayloadBytes = $null
        $Payload = $null
        $PayloadBytes = $null
        if (-not $Process.WaitForExit($TimeoutMilliseconds)) {
            try { $Process.Kill() } catch {}
            throw "Timeout della procedura locale protetta."
        }
        $Output = $OutputTask.Result
        $IgnoredErrorOutput = $ErrorTask.Result
        if ([string]::IsNullOrWhiteSpace($Output)) {
            throw "La procedura locale protetta non ha restituito un risultato valido."
        }
        try {
            $Envelope = $Output | ConvertFrom-Json
        } catch {
            throw "La procedura locale protetta ha restituito dati non validi."
        }
        if ($null -eq $Envelope -or -not ($Envelope.PSObject.Properties.Name -contains "ok")) {
            throw "La procedura locale protetta ha restituito una struttura inattesa."
        }
        return $Envelope
    } finally {
        $Payload = $null
        if ($null -ne $Process) { $Process.Dispose() }
    }
}

$script:LocalProjectEntropy = [System.Text.Encoding]::UTF8.GetBytes("Passbolt Migration Assistant local project schema 1")
$script:MaximumLocalProjectFileBytes = 32MB

function Protect-LocalProjectText([string]$PlainText) {
    $PlainBytes = (New-Object System.Text.UTF8Encoding($false, $true)).GetBytes($PlainText)
    try {
        return [System.Security.Cryptography.ProtectedData]::Protect(
            $PlainBytes,
            $script:LocalProjectEntropy,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
    } finally {
        if ($null -ne $PlainBytes) { [Array]::Clear($PlainBytes, 0, $PlainBytes.Length) }
    }
}

function Unprotect-LocalProjectText([byte[]]$CipherBytes) {
    try {
        $PlainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $CipherBytes,
            $script:LocalProjectEntropy,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
    } catch {
        throw "Il progetto non puo' essere decifrato dall'utente Windows corrente oppure e' stato alterato."
    }
    try {
        if ($PlainBytes.Length -gt 16MB) { throw "Il progetto decifrato supera il limite di sicurezza in byte." }
        return (New-Object System.Text.UTF8Encoding($false, $true)).GetString($PlainBytes)
    } catch [System.Text.DecoderFallbackException] {
        throw "Il progetto decifrato non contiene JSON UTF-8 valido."
    } finally {
        if ($null -ne $PlainBytes) { [Array]::Clear($PlainBytes, 0, $PlainBytes.Length) }
    }
}

function Write-AtomicUtf8File([string]$Path, [string]$Content) {
    $FullPath = [IO.Path]::GetFullPath($Path)
    $Directory = [IO.Path]::GetDirectoryName($FullPath)
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        throw "La cartella scelta per il progetto non e' disponibile."
    }
    $TemporaryPath = Join-Path $Directory (([IO.Path]::GetFileName($FullPath)) + ".tmp-" + [guid]::NewGuid().ToString("N"))
    $BackupPath = Join-Path $Directory (([IO.Path]::GetFileName($FullPath)) + ".bak-" + [guid]::NewGuid().ToString("N"))
    $Bytes = (New-Object System.Text.UTF8Encoding($false, $true)).GetBytes($Content)
    try {
        $Stream = New-Object System.IO.FileStream(
            $TemporaryPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None,
            4096,
            [IO.FileOptions]::WriteThrough
        )
        try {
            $Stream.Write($Bytes, 0, $Bytes.Length)
            $Stream.Flush($true)
        } finally {
            $Stream.Dispose()
        }
        if (Test-Path -LiteralPath $FullPath -PathType Leaf) {
            [IO.File]::Replace($TemporaryPath, $FullPath, $BackupPath)
        } else {
            [IO.File]::Move($TemporaryPath, $FullPath)
        }
    } finally {
        if ($null -ne $Bytes) { [Array]::Clear($Bytes, 0, $Bytes.Length) }
        if (Test-Path -LiteralPath $TemporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $TemporaryPath -Force
        }
        if (Test-Path -LiteralPath $BackupPath -PathType Leaf) {
            Remove-Item -LiteralPath $BackupPath -Force
        }
    }
}

function Get-LocalProjectFileSelection([switch]$ReviewContext) {
    $Paths = New-Object System.Collections.Generic.List[string]
    if ($ReviewContext -and @($script:ReviewedSourceFiles).Count -gt 0) {
        foreach ($RelativePath in @($script:ReviewedSourceFiles)) { $Paths.Add([string]$RelativePath) }
    } else {
        foreach ($Row in @($FilesGrid.SelectedItems)) { $Paths.Add([string]$Row.RelativePath) }
    }
    return $Paths.ToArray()
}

function Get-LocalProjectCandidateSelection([switch]$ReviewContext) {
    $Selections = New-Object System.Collections.Generic.List[object]
    if (-not $ReviewContext) { return $Selections.ToArray() }
    foreach ($Row in @($ReviewCandidatesGrid.SelectedItems | Where-Object { $_.Status -eq "ready" })) {
        $Selections.Add([pscustomobject][ordered]@{
            candidate_id = [string]$Row.CandidateId
            source_sha256 = [string]$Row.SourceHash
        })
    }
    return $Selections.ToArray()
}

function Start-LocalProjectEnvelopeCreation([object]$Normalized, [object]$Context) {
    $ProjectText = $Normalized.project | ConvertTo-Json -Depth 14 -Compress
    $CipherBytes = $null
    try {
        $CipherBytes = Protect-LocalProjectText $ProjectText
        $Ciphertext = [Convert]::ToBase64String($CipherBytes)
    } finally {
        if ($null -ne $CipherBytes) { [Array]::Clear($CipherBytes, 0, $CipherBytes.Length) }
        $CipherBytes = $null
        $ProjectText = $null
    }
    $EnvelopeRequest = [pscustomobject]@{
        command = "create-envelope"
        ciphertext = $Ciphertext
        saved_at_utc = [string]$Context.SavedAtUtc
    }
    $Context.Digest = [string]$Normalized.project.digest
    $OperationParameters = @{
        Name = "Protezione progetto locale"
        Category = "write"
        WorkKind = "SecureJsonProcess"
        Payload = New-SecureJsonOperationPayload $PythonExecutable @($LocalProjectScript, "--secure-json") $EnvelopeRequest
        Context = $Context
        OnSuccess = {
            param($Envelope, $Operation)
            if (-not [bool]$Envelope.ok) {
                $FailureMessage = Get-SecureErrorMessage $Envelope
                Add-Activity "Salvataggio del progetto locale non riuscito."
                [System.Windows.MessageBox]::Show($FailureMessage, "Progetto non salvato", "OK", "Error") | Out-Null
                return
            }
            try {
                $EnvelopeText = $Envelope.result.envelope | ConvertTo-Json -Depth 8 -Compress
                Write-AtomicUtf8File ([string]$Operation.Context.FileName) $EnvelopeText
                $DigestPrefix = ([string]$Operation.Context.Digest).Substring(0, 8).ToUpperInvariant()
                Add-Activity "Progetto locale protetto salvato: $([int]$Operation.Context.SelectedFileCount) file, $([int]$Operation.Context.SelectedCandidateCount) candidati tecnici, digest $DigestPrefix."
                [System.Windows.MessageBox]::Show(
                    "Progetto salvato con protezione DPAPI per l'utente Windows corrente." + [Environment]::NewLine + [Environment]::NewLine + "Non contiene fingerprint fidate, sessioni, chiavi, passphrase, MFA, password, correzioni o piani. Non e' trasferibile a un altro utente o computer.",
                    "Progetto locale salvato",
                    "OK",
                    "Information"
                ) | Out-Null
            } catch {
                Add-Activity "Salvataggio del progetto locale non riuscito."
                [System.Windows.MessageBox]::Show($_.Exception.Message, "Progetto non salvato", "OK", "Error") | Out-Null
            }
        }
        OnFailure = {
            param($FailureMessage, $Operation)
            Add-Activity "Salvataggio del progetto locale non riuscito."
            [System.Windows.MessageBox]::Show($FailureMessage, "Progetto non salvato", "OK", "Error") | Out-Null
        }
    }
    [void](Start-UiOperation @OperationParameters)
    $Ciphertext = $null
}

function Save-LocalPreparationProject([switch]$ReviewContext) {
    $PlannedServerOrigin = $PlannedPassboltUrl.Text.Trim()
    if (-not $PlannedServerOrigin) {
        [System.Windows.MessageBox]::Show("Indicare l'URL HTTPS della destinazione prevista. Il valore verra' validato solo localmente e la fingerprint non verra' salvata nel progetto.", "Destinazione non indicata", "OK", "Warning") | Out-Null
        return
    }
    if ($null -eq $script:InventoryResult -or -not $script:InventoryFolder) {
        [System.Windows.MessageBox]::Show("Eseguire prima l'inventario della cartella sorgente.", "Inventario necessario", "OK", "Warning") | Out-Null
        return
    }
    $SelectedFiles = @(Get-LocalProjectFileSelection -ReviewContext:$ReviewContext)
    if ($SelectedFiles.Count -lt 1) {
        [System.Windows.MessageBox]::Show("Selezionare almeno un file da includere nel progetto locale.", "Selezione mancante", "OK", "Warning") | Out-Null
        return
    }
    $SelectedCandidates = @(Get-LocalProjectCandidateSelection -ReviewContext:$ReviewContext)
    $SavedAtUtc = [DateTime]::UtcNow.ToString("o")
    $Request = [pscustomobject]@{
        command = "normalize-project"
        project = [pscustomobject][ordered]@{
            schema_version = 1
            kind = "passbolt-migration-preparation"
            app_version = "0.29.0-beta.1"
            saved_at_utc = $SavedAtUtc
            server_origin = [string]$PlannedServerOrigin
            source_root = [string]$script:InventoryFolder
            source_mapping_profile = $script:SourceMappingProfile
            selected_files = $SelectedFiles
            selected_candidates = $SelectedCandidates
        }
    }
    $Dialog = New-Object System.Windows.Forms.SaveFileDialog
    $Dialog.Title = "Salva progetto locale protetto"
    $Dialog.Filter = "Progetto Passbolt protetto (*.pbproj)|*.pbproj"
    $Dialog.DefaultExt = "pbproj"
    $Dialog.AddExtension = $true
    $Dialog.OverwritePrompt = $true
    $Dialog.FileName = "progetto-passbolt-$(Get-Date -Format 'yyyyMMdd-HHmm').pbproj"
    try {
        if ($Dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $Context = [pscustomobject]@{
            FileName = $Dialog.FileName
            SavedAtUtc = $SavedAtUtc
            SelectedFileCount = $SelectedFiles.Count
            SelectedCandidateCount = $SelectedCandidates.Count
            Digest = ""
        }
        $OperationParameters = @{
            Name = "Normalizzazione progetto locale"
            Category = "write"
            WorkKind = "SecureJsonProcess"
            Payload = New-SecureJsonOperationPayload $PythonExecutable @($LocalProjectScript, "--secure-json") $Request
            Context = $Context
            OnSuccess = {
                param($Envelope, $Operation)
                if (-not [bool]$Envelope.ok) {
                    $FailureMessage = Get-SecureErrorMessage $Envelope
                    Add-Activity "Salvataggio del progetto locale non riuscito."
                    [System.Windows.MessageBox]::Show($FailureMessage, "Progetto non salvato", "OK", "Error") | Out-Null
                    return
                }
                try { Start-LocalProjectEnvelopeCreation $Envelope.result $Operation.Context }
                catch {
                    Add-Activity "Salvataggio del progetto locale non riuscito."
                    [System.Windows.MessageBox]::Show($_.Exception.Message, "Progetto non salvato", "OK", "Error") | Out-Null
                }
            }
            OnFailure = {
                param($FailureMessage, $Operation)
                Add-Activity "Salvataggio del progetto locale non riuscito."
                [System.Windows.MessageBox]::Show($FailureMessage, "Progetto non salvato", "OK", "Error") | Out-Null
            }
        }
        [void](Start-UiOperation @OperationParameters)
    } finally {
        $SelectedCandidates = @()
        $Dialog.Dispose()
    }
}
function Restore-LocalPreparationProject([object]$Project) {
    if (Test-ImportSessionActive) {
        Stop-ImportSession "Sessione chiusa prima del ripristino di un progetto locale." $false
    }
    $script:ConnectionVerified = $false
    $script:VerifiedUrl = ""
    $script:VerifiedFingerprint = ""
    $DetectedFingerprint.Text = "Fingerprint: non ancora rilevata"
    $ConnectionDot.Fill = Get-Brush "#98A5B1"
    $ConnectionStatus.Text = "Da verificare dopo il ripristino"
    $ConnectionStatus.Foreground = Get-Brush "#C77D00"
    $script:InventoryResult = $null
    $script:InventoryFolder = ""
    $script:AllInventoryRows = @()
    $script:ReviewResult = $null
    $script:AllReviewRows = @()
    $script:ReviewedSourceFiles = @()
    $script:ReviewFilePasswords = @{}
    $script:SourceMappingProfile = $Project.source_mapping_profile
    $script:PendingProjectSourceRoot = [string]$Project.source_root
    $script:PendingProjectSelectedFiles = @($Project.selected_files | ForEach-Object { [string]$_ })
    $script:PendingProjectSelectedCandidates = @($Project.selected_candidates)
    $script:LoadedProjectDigest = [string]$Project.digest
    $FilesGrid.ItemsSource = $null
    $ReviewCandidatesGrid.ItemsSource = $null
    Reset-ImportWorkflow
    Update-SourceMappingProfileState
    $PlannedPassboltUrl.Text = [string]$Project.server_origin
    $PassboltUrl.Text = [string]$Project.server_origin
    $ClientFolder.Text = [string]$Project.source_root
    $MetricClients.Text = [string][char]0x2014
    $MetricFiles.Text = [string][char]0x2014
    $MetricSize.Text = [string][char]0x2014
    $MetricIgnored.Text = [string][char]0x2014
    $InventoryRoot.Text = "Progetto ripristinato: rieseguire l'inventario locale"
    $ReviewSummary.Text = "Il progetto richiede una nuova revisione locale"
    $ReviewMetricFiles.Text = [string][char]0x2014
    $ReviewMetricCandidates.Text = [string][char]0x2014
    $ReviewMetricReady.Text = [string][char]0x2014
    $ReviewMetricIncomplete.Text = [string][char]0x2014
    $WarningsPanel.Visibility = "Collapsed"
    $ReviewWarningsPanel.Visibility = "Collapsed"
    Show-Page "Configuration"
    Update-ConfigurationState
    $DigestPrefix = ([string]$Project.digest).Substring(0, 8).ToUpperInvariant()
    Add-Activity "Progetto locale ripristinato (digest $DigestPrefix); inventario e revisione restano da ricostruire localmente, la connessione verra' verificata in fase 04."
}

function Start-LocalProjectNormalization([string]$ProjectText) {
    $Request = [pscustomobject]@{
        command = "normalize-project-json"
        project_json = $ProjectText
    }
    $OperationParameters = @{
        Name = "Validazione progetto locale"
        Category = "read"
        WorkKind = "SecureJsonProcess"
        Payload = New-SecureJsonOperationPayload $PythonExecutable @($LocalProjectScript, "--secure-json") $Request
        OnSuccess = {
            param($Envelope, $Operation)
            if (-not [bool]$Envelope.ok) {
                $FailureMessage = Get-SecureErrorMessage $Envelope
                Add-Activity "Apertura del progetto locale non riuscita."
                [System.Windows.MessageBox]::Show($FailureMessage, "Progetto non aperto", "OK", "Error") | Out-Null
                return
            }
            try {
                $Project = $Envelope.result.project
                Restore-LocalPreparationProject $Project
                $MissingSource = -not (Test-Path -LiteralPath ([string]$Project.source_root) -PathType Container)
                $AvailabilityMessage = if ($MissingSource) {
                    "La cartella sorgente salvata non e' disponibile: selezionarne una valida prima di continuare."
                } else {
                    "Continuare con l'inventario locale: le selezioni saranno ricostruite senza aprire automaticamente i documenti."
                }
                $Message = "Il progetto e' stato decifrato per l'utente Windows corrente." + [Environment]::NewLine + [Environment]::NewLine + $AvailabilityMessage + [Environment]::NewLine + [Environment]::NewLine + "La destinazione non e' stata contattata. La fingerprint verra' rilevata e richiedera' una nuova conferma indipendente in fase 04."
                [System.Windows.MessageBox]::Show($Message, "Progetto locale ripristinato", "OK", $(if ($MissingSource) { "Warning" } else { "Information" })) | Out-Null
            } catch {
                Add-Activity "Apertura del progetto locale non riuscita."
                [System.Windows.MessageBox]::Show($_.Exception.Message, "Progetto non aperto", "OK", "Error") | Out-Null
            }
        }
        OnFailure = {
            param($FailureMessage, $Operation)
            Add-Activity "Apertura del progetto locale non riuscita."
            [System.Windows.MessageBox]::Show($FailureMessage, "Progetto non aperto", "OK", "Error") | Out-Null
        }
    }
    [void](Start-UiOperation @OperationParameters)
    $ProjectText = $null
}

function Open-LocalPreparationProject {
    $Dialog = New-Object System.Windows.Forms.OpenFileDialog
    $Dialog.Title = "Apri progetto locale protetto"
    $Dialog.Filter = "Progetto Passbolt protetto (*.pbproj)|*.pbproj"
    $Dialog.Multiselect = $false
    try {
        if ($Dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $File = Get-Item -LiteralPath $Dialog.FileName -ErrorAction Stop
        if ($File.Length -lt 1 -or $File.Length -gt $script:MaximumLocalProjectFileBytes) {
            throw "Il file progetto e' vuoto o supera il limite di sicurezza in byte."
        }
        try {
            $EnvelopeText = [IO.File]::ReadAllText($File.FullName, (New-Object System.Text.UTF8Encoding($false, $true)))
        } catch [System.Text.DecoderFallbackException] {
            throw "Il file progetto non contiene JSON UTF-8 valido."
        }
        $Request = [pscustomobject]@{
            command = "open-envelope-json"
            envelope_json = $EnvelopeText
        }
        $OperationParameters = @{
            Name = "Apertura progetto locale"
            Category = "read"
            WorkKind = "SecureJsonProcess"
            Payload = New-SecureJsonOperationPayload $PythonExecutable @($LocalProjectScript, "--secure-json") $Request
            OnSuccess = {
                param($Envelope, $Operation)
                $CipherBytes = $null
                $ProjectText = $null
                try {
                    if (-not [bool]$Envelope.ok) { throw (Get-SecureErrorMessage $Envelope) }
                    try { $CipherBytes = [Convert]::FromBase64String([string]$Envelope.result.ciphertext) }
                    catch { throw "Il contenuto protetto del progetto non usa Base64 valido." }
                    $Envelope.result.ciphertext = $null
                    $ProjectText = Unprotect-LocalProjectText $CipherBytes
                    Start-LocalProjectNormalization $ProjectText
                } catch {
                    Add-Activity "Apertura del progetto locale non riuscita."
                    [System.Windows.MessageBox]::Show($_.Exception.Message, "Progetto non aperto", "OK", "Error") | Out-Null
                } finally {
                    if ($null -ne $CipherBytes) { [Array]::Clear($CipherBytes, 0, $CipherBytes.Length) }
                    $ProjectText = $null
                }
            }
            OnFailure = {
                param($FailureMessage, $Operation)
                Add-Activity "Apertura del progetto locale non riuscita."
                [System.Windows.MessageBox]::Show($FailureMessage, "Progetto non aperto", "OK", "Error") | Out-Null
            }
        }
        [void](Start-UiOperation @OperationParameters)
        $EnvelopeText = $null
    } catch {
        Add-Activity "Apertura del progetto locale non riuscita."
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Progetto non aperto", "OK", "Error") | Out-Null
    } finally {
        $Dialog.Dispose()
    }
}
function Apply-PendingProjectInventorySelection {
    if (@($script:PendingProjectSelectedFiles).Count -lt 1) { return }
    $Expected = @{}
    foreach ($RelativePath in @($script:PendingProjectSelectedFiles)) {
        $Identity = ([string]$RelativePath).Replace("\", "/").ToLowerInvariant()
        $Expected[$Identity] = $true
    }
    $FilesGrid.UnselectAll()
    $Applied = 0
    foreach ($Row in @($script:AllInventoryRows)) {
        $Identity = ([string]$Row.RelativePath).Replace("\", "/").ToLowerInvariant()
        if ($Expected.ContainsKey($Identity)) {
            [void]$FilesGrid.SelectedItems.Add($Row)
            $Applied++
            $Expected.Remove($Identity)
        }
    }
    $Missing = $Expected.Count
    $script:PendingProjectSelectedFiles = @()
    Update-ReviewSelectionState
    Add-Activity "Selezione progetto ricostruita: $Applied file disponibili, $Missing mancanti."
    if ($Missing -gt 0) {
        [System.Windows.MessageBox]::Show("$Missing file salvati nel progetto non sono piu' presenti nell'inventario e non sono stati selezionati.", "Progetto parzialmente ripristinato", "OK", "Warning") | Out-Null
    }
}

function Apply-PendingProjectCandidateSelection {
    if (@($script:PendingProjectSelectedCandidates).Count -lt 1) { return }
    $Expected = @{}
    foreach ($Selection in @($script:PendingProjectSelectedCandidates)) {
        $Expected[([string]$Selection.candidate_id).ToLowerInvariant()] = ([string]$Selection.source_sha256).ToLowerInvariant()
    }
    $ReviewCandidatesGrid.UnselectAll()
    $Applied = 0
    foreach ($Row in @($script:AllReviewRows)) {
        $CandidateId = ([string]$Row.CandidateId).ToLowerInvariant()
        if (
            $Expected.ContainsKey($CandidateId) -and
            ([string]$Row.SourceHash).ToLowerInvariant() -eq [string]$Expected[$CandidateId] -and
            [string]$Row.Status -eq "ready"
        ) {
            [void]$ReviewCandidatesGrid.SelectedItems.Add($Row)
            $Applied++
            $Expected.Remove($CandidateId)
        }
    }
    $Missing = $Expected.Count
    $script:PendingProjectSelectedCandidates = @()
    Update-ImportSelectionState
    Add-Activity "Candidati progetto ricostruiti dopo rilettura: $Applied pronti, $Missing non corrispondenti."
    if ($Missing -gt 0) {
        [System.Windows.MessageBox]::Show("$Missing candidati salvati non coincidono piu' con identificativo, hash sorgente e stato Pronto. Non sono stati selezionati.", "Candidati non ripristinati", "OK", "Warning") | Out-Null
    }
}

function Test-ImportSessionActive {
    if ($null -eq $script:ImportSessionProcess -or -not $script:ImportSessionId) { return $false }
    try {
        return -not $script:ImportSessionProcess.HasExited
    } catch {
        return $false
    }
}

function Start-ImportSessionProcess {
    if ($null -ne $script:ImportSessionProcess) {
        Stop-ImportSession "" $false
    }
    if (-not (Test-Path -LiteralPath $script:InventoryFolder -PathType Container)) {
        throw "La cartella clienti della sessione non e' disponibile."
    }

    $StartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $StartInfo.FileName = $PythonExecutable
    $Arguments = @(
        $ImportScript,
        "--session",
        "--root", $script:InventoryFolder,
        "--node", $NodeExecutable,
        "--crypto-script", $CryptoScript
    )
    $StartInfo.Arguments = (@($Arguments | ForEach-Object { ConvertTo-ProcessArgument ([string]$_) }) -join ' ')
    $StartInfo.WorkingDirectory = $ProjectRoot
    $StartInfo.UseShellExecute = $false
    $StartInfo.CreateNoWindow = $true
    $StartInfo.RedirectStandardInput = $true
    $StartInfo.RedirectStandardOutput = $true
    $StartInfo.RedirectStandardError = $true
    $StartInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $StartInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)

    $Process = New-Object System.Diagnostics.Process
    $Process.StartInfo = $StartInfo
    try {
        if (-not $Process.Start()) { throw "Impossibile avviare la sessione locale protetta." }
        $script:ImportSessionProcess = $Process
        $script:ImportSessionErrorTask = $Process.StandardError.ReadToEndAsync()
    } catch {
        $Process.Dispose()
        throw
    }
}

function Invoke-ImportSessionJson(
    [object]$InputObject,
    [int]$TimeoutMilliseconds = 180000,
    [scriptblock]$ProgressHandler = $null
) {
    if (-not (Test-ImportSessionActive) -and [string]$InputObject.command -ne "session-open") {
        throw "La sessione sicura di importazione non e' attiva."
    }
    if ($null -eq $script:ImportSessionProcess) {
        throw "Il coordinatore della sessione sicura non e' disponibile."
    }
    try {
        if ($script:ImportSessionProcess.HasExited) {
            throw "La sessione sicura locale si e' chiusa inaspettatamente."
        }
    } catch {
        throw "La sessione sicura locale non e' piu disponibile."
    }

    $Payload = $InputObject | ConvertTo-Json -Depth 14 -Compress
    if ($Payload.Length -gt 67108864) {
        throw "La richiesta della sessione sicura e' troppo grande."
    }
    $PayloadBytes = $null
    try {
        $PayloadBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Payload + "`n")
        $script:ImportSessionProcess.StandardInput.BaseStream.Write($PayloadBytes, 0, $PayloadBytes.Length)
        $script:ImportSessionProcess.StandardInput.BaseStream.Flush()
        $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            $Remaining = $TimeoutMilliseconds - [int]$Stopwatch.ElapsedMilliseconds
            if ($Remaining -le 0) {
                try { $script:ImportSessionProcess.Kill() } catch {}
                throw "Timeout della sessione sicura locale."
            }
            $OutputTask = $script:ImportSessionProcess.StandardOutput.ReadLineAsync()
            if (-not $OutputTask.Wait($Remaining)) {
                try { $script:ImportSessionProcess.Kill() } catch {}
                throw "Timeout della sessione sicura locale."
            }
            $Output = $OutputTask.Result
            if ([string]::IsNullOrWhiteSpace($Output) -or $Output.Length -gt 67108864) {
                throw "La sessione sicura locale non ha restituito un risultato valido."
            }
            try {
                $Envelope = $Output | ConvertFrom-Json
            } catch {
                throw "La sessione sicura locale ha restituito dati non validi."
            }
            if ($null -ne $Envelope -and [string]$Envelope.type -eq "progress") {
                if ($null -eq $ProgressHandler) {
                    throw "La sessione sicura locale ha restituito un avanzamento inatteso."
                }
                & $ProgressHandler $Envelope
                $script:ImportSessionLastActivityUtc = [DateTime]::UtcNow
                continue
            }
            if ($null -eq $Envelope -or -not ($Envelope.PSObject.Properties.Name -contains "ok")) {
                throw "La sessione sicura locale ha restituito una struttura inattesa."
            }
            $script:ImportSessionLastActivityUtc = [DateTime]::UtcNow
            return $Envelope
        }
    } catch {
        try {
            if ($null -ne $script:ImportSessionProcess -and -not $script:ImportSessionProcess.HasExited) {
                $script:ImportSessionProcess.Kill()
                [void]$script:ImportSessionProcess.WaitForExit(5000)
            }
        } catch {}
        throw
    } finally {
        $Payload = $null
        $PayloadBytes = $null
    }
}

function Get-ImportSessionIdentityText {
    if (-not (Test-ImportSessionActive) -or $null -eq $script:ImportSessionInfo) {
        return "Avviare la sessione sicura per verificare identita' e piano."
    }
    $Info = $script:ImportSessionInfo
    $DisplayName = ("$($Info.user.first_name) $($Info.user.last_name)").Trim()
    if (-not $DisplayName) { $DisplayName = [string]$Info.user.username }
    return "Sessione attiva: $DisplayName <$($Info.user.username)> | chiave $($Info.user_key_fingerprint) | $($Info.authentication) | timeout inattivita $($script:ImportSessionIdleTimeoutMinutes) min"
}

function Show-Phase04Workspace(
    [ValidateSet("new_import", "recovery", "existing_acl")]
    [string]$Workspace,
    [switch]$SkipRefresh
) {
    $script:Phase04Workspace = $Workspace
    $IsAclWorkspace = $Workspace -eq "existing_acl"
    $MigrationWorkspace.Visibility = if ($IsAclWorkspace) { "Collapsed" } else { "Visible" }
    $ExistingAclWorkspace.Visibility = if ($IsAclWorkspace) { "Visible" } else { "Collapsed" }
    $MigrationDestinationPanel.Visibility = if ($IsAclWorkspace) { "Collapsed" } else { "Visible" }
    $AclContextPanel.Visibility = if ($IsAclWorkspace) { "Visible" } else { "Collapsed" }
    $NewImportWorkspace.Visibility = if ($Workspace -eq "new_import") { "Visible" } else { "Collapsed" }
    $RecoveryWorkspace.Visibility = if ($Workspace -eq "recovery") { "Visible" } else { "Collapsed" }
    $NewImportModeButton.IsChecked = $Workspace -eq "new_import"
    $RecoveryModeButton.IsChecked = $Workspace -eq "recovery"

    if ($IsAclWorkspace) {
        $ImportPageTitle.Text = "Gestione permessi esistenti"
        $ImportSummary.Text = "Spazio separato dalla migrazione per consultare, simulare e applicare ACL"
        $AclWorkspaceButton.Content = "Torna alla migrazione"
        Update-AclViewerState
        if (-not $SkipRefresh) { Refresh-AclRecoveryGuard }
        return
    }

    $script:LastMigrationWorkspace = $Workspace
    $AclWorkspaceButton.Content = "Gestisci ACL esistenti"
    if ($Workspace -eq "recovery") {
        $ImportPageTitle.Text = "Recupero import interrotto"
        $ImportSummary.Text = "Associa i registri locali ai sorgenti prima di ogni verifica remota"
        if (-not $SkipRefresh -and $script:RecoveryBatches.Count -eq 0 -and $null -eq $script:RecoveryPlan) {
            Refresh-RecoveryBatches -Quiet
        }
    } else {
        $ImportPageTitle.Text = "Importazione controllata"
        $ImportSummary.Text = if ($script:ImportRecoveryRequired) {
            "Nuove importazioni bloccate: completare prima il recupero del journal locale"
        } elseif ($script:ImportCandidates.Count -gt 0) {
            "$($script:ImportCandidates.Count) candidati pronti selezionati dalla revisione"
        } else {
            "Prepara i candidati dalla revisione"
        }
    }
}

function Update-ImportSessionState {
    $Active = Test-ImportSessionActive
    $PrivateKeyPath.IsEnabled = -not $Active
    $BrowseKeyButton.IsEnabled = -not $Active
    $KeyPassphrase.IsEnabled = -not $Active
    $MfaTotpCode.IsEnabled = -not $Active
    if ($Active) {
        $ImportSessionButton.Content = "Chiudi sessione"
        $ImportSessionButton.IsEnabled = $true
        $DryRunButton.IsEnabled = (
            -not $script:ImportRecoveryRequired -and
            $script:ConnectionVerified -and
            $script:ImportCandidates.Count -gt 0 -and
            $script:ImportSessionRoot -eq $script:InventoryFolder -and
            $null -eq $script:RecoveryPlan
        )
        if ($null -eq $script:ImportPlan) { $ImportIdentity.Text = Get-ImportSessionIdentityText }
    } else {
        $ImportSessionButton.Content = "Avvia sessione"
        $PreparedCandidateCount = [Math]::Max($script:ImportCandidates.Count, $script:RecoveryCandidates.Count)
        $ImportSessionButton.IsEnabled = ($script:ConnectionVerified -and $PreparedCandidateCount -gt 0 -and (Test-Path -LiteralPath $script:InventoryFolder -PathType Container))
        $DryRunButton.IsEnabled = $false
        if ($null -eq $script:ImportPlan) { $ImportIdentity.Text = "Avviare la sessione sicura per verificare identita' e piano." }
    }
    $NewImportModeButton.IsEnabled = -not $script:ImportRecoveryRequired
    $DryRunButton.ToolTip = if ($script:ImportRecoveryRequired) {
        "Recupero obbligatorio: verificare o gestire il journal locale prima di preparare una nuova importazione."
    } elseif ($Active) {
        "Esegue preflight e dry-run senza inviare scritture."
    } else {
        "Avviare prima la sessione sicura Passbolt."
    }
    Update-ExecuteImportState
    Update-RecoveryActionState
    Update-PermissionEditorState
    Update-AclViewerState
}

function Stop-ImportSession(
    [string]$Reason = "",
    [bool]$ResetPlan = $true
) {
    $Process = $script:ImportSessionProcess
    if ($null -ne $Process) {
        try {
            try { $Process.StandardInput.Close() } catch {}
            if (-not $Process.HasExited) { try { $Process.Kill() } catch {} }
        } finally {
            $Process.Dispose()
        }
    }
    $script:ImportSessionProcess = $null
    $script:ImportSessionErrorTask = $null
    $script:ImportSessionId = ""
    $script:ImportSessionInfo = $null
    $script:ImportSessionLastActivityUtc = [DateTime]::MinValue
    $script:ImportSessionRoot = ""
    $script:ImportSessionKeyPath = ""
    $script:PermissionCatalog = @()
    $script:PermissionCatalogSessionId = ""
    $script:AclCatalogSessionId = ""
    $script:AllAclObjectRows = @()
    $AclObjectsGrid.ItemsSource = $null
    $AclPermissionsGrid.ItemsSource = $null
    $AclObjectSummary.Text = "Seleziona un oggetto per visualizzare la relativa ACL."
    Reset-AclPlan "Sessione chiusa. Avviare una nuova sessione e rileggere il catalogo ACL."
    $KeyPassphrase.Clear()
    $MfaTotpCode.Clear()
    if ($ResetPlan) {
        $Status = if ($Reason) { $Reason } else { "Sessione chiusa. Avviare una nuova sessione prima del dry-run." }
        Reset-ImportPlan $Status
        if ($null -ne $script:RecoveryBatchDetails) {
            Reset-RecoveryPlan "Sessione chiusa. Il lotto resta associato ai sorgenti; avviare una nuova sessione prima della verifica."
        } else {
            Reset-RecoveryPlan
        }
    }
    Update-ImportSessionState
    if ($Reason -and -not $script:ClosingApplication) { Add-Activity $Reason }
}

function Close-ImportSessionAsync(
    [string]$Reason = "Sessione autenticata chiusa dall'utente.",
    [bool]$ResetPlan = $true
) {
    if (-not (Test-ImportSessionActive) -or -not $script:ImportSessionId) {
        Stop-ImportSession $Reason $ResetPlan
        return
    }
    $Request = [pscustomobject][ordered]@{
        command = "session-close"
        session_id = $script:ImportSessionId
    }
    $OperationParameters = @{
        Name = "Chiusura sessione autenticata"
        Category = "verify"
        WorkKind = "ImportSessionJson"
        Payload = New-ImportSessionOperationPayload $Request 10000
        Context = [pscustomobject]@{ Reason = $Reason; ResetPlan = $ResetPlan }
        OnSuccess = {
            param($Envelope, $Operation)
            Stop-ImportSession ([string]$Operation.Context.Reason) ([bool]$Operation.Context.ResetPlan)
        }
        OnFailure = {
            param($FailureMessage, $Operation)
            Stop-ImportSession ([string]$Operation.Context.Reason) ([bool]$Operation.Context.ResetPlan)
        }
    }
    [void](Start-UiOperation @OperationParameters)
}

function Test-TerminalImportSessionError($Envelope) {
    if ($null -eq $Envelope -or $null -eq $Envelope.error) { return $false }
    $Code = [string]$Envelope.error.code
    return $Code -in @(
        "IMPORT_SESSION_EXPIRED",
        "IMPORT_SESSION_MFA_EXPIRED",
        "IMPORT_SESSION_NOT_OPEN",
        "IMPORT_SESSION_ID_MISMATCH",
        "IMPORT_SESSION_IDENTITY_CHANGED"
    )
}

function Open-ImportSession {
    if (-not $script:ConnectionVerified -or -not $script:VerifiedUrl -or -not $script:VerifiedFingerprint) {
        [System.Windows.MessageBox]::Show("Verificare il server e confermare la fingerprint nella parte superiore della fase 04.", "Connessione non verificata", "OK", "Warning") | Out-Null
        return
    }
    if (($script:ImportCandidates.Count -lt 1 -and $script:RecoveryCandidates.Count -lt 1) -or -not (Test-Path -LiteralPath $script:InventoryFolder -PathType Container)) {
        [System.Windows.MessageBox]::Show("Preparare almeno un candidato pronto oppure associare un lotto di recupero alla cartella sorgente.", "Importazione non preparata", "OK", "Warning") | Out-Null
        return
    }
    $KeyPath = $PrivateKeyPath.Text.Trim()
    if (-not (Test-Path -LiteralPath $KeyPath -PathType Leaf)) {
        [System.Windows.MessageBox]::Show("Selezionare un file di chiave privata OpenPGP accessibile.", "Chiave privata mancante", "OK", "Warning") | Out-Null
        return
    }
    if ($KeyPassphrase.Password.Length -lt 1) {
        [System.Windows.MessageBox]::Show("Inserire la passphrase della chiave privata.", "Passphrase mancante", "OK", "Warning") | Out-Null
        return
    }
    if ($MfaTotpCode.Password.Length -gt 0 -and $MfaTotpCode.Password -notmatch '^\d{6}$') {
        [System.Windows.MessageBox]::Show("Il codice MFA TOTP deve contenere esattamente 6 cifre.", "Codice MFA non valido", "OK", "Warning") | Out-Null
        return
    }

    $Passphrase = $KeyPassphrase.Password
    $MfaCode = $MfaTotpCode.Password
    $KeyPassphrase.Clear()
    $MfaTotpCode.Clear()
    $ImportPlanStatus.Text = "Apertura della sessione autenticata in corso..."
    Add-Activity "Avvio sessione autenticata GPGAuth per il workflow di importazione."
    try {
        Start-ImportSessionProcess
        $OpenRequest = [pscustomobject][ordered]@{
            command = "session-open"
            base_url = $script:VerifiedUrl
            expected_server_fingerprint = $script:VerifiedFingerprint
            private_key_path = $KeyPath
            passphrase = $Passphrase
            mfa_totp = $MfaCode
        }
        $Context = [pscustomobject]@{ KeyPath = $KeyPath; InventoryFolder = $script:InventoryFolder }
        $Started = Start-UiOperation "Apertura sessione autenticata" "verify" "ImportSessionJson" `
            (New-ImportSessionOperationPayload $OpenRequest) `
            -Context $Context `
            -OnSuccess {
                param($Envelope, $Operation)
                try {
                    if (-not [bool]$Envelope.ok) { throw (Get-SecureErrorMessage $Envelope) }
                    if (-not [string]$Envelope.result.session_id) { throw "La sessione autenticata non ha restituito un identificatore valido." }
                    $script:ImportSessionId = [string]$Envelope.result.session_id
                    $script:ImportSessionInfo = $Envelope.result
                    $script:ImportSessionRoot = [string]$Operation.Context.InventoryFolder
                    $script:ImportSessionKeyPath = [string]$Operation.Context.KeyPath
                    $script:ImportSessionLastActivityUtc = [DateTime]::UtcNow
                    $script:PermissionCatalog = @()
                    $script:PermissionCatalogSessionId = ""
                    $script:AclCatalogSessionId = ""
                    $script:AllAclObjectRows = @()
                    $AclObjectsGrid.ItemsSource = $null
                    $AclPermissionsGrid.ItemsSource = $null
                    $AclObjectSummary.Text = "Seleziona un oggetto per visualizzare la relativa ACL."
                    Reset-AclPlan "Sessione aperta. Leggere il catalogo ACL prima di calcolare un piano."
                    Reset-ImportPlan "Sessione autenticata attiva. Configurare la destinazione ed eseguire il dry-run."
                    if ($null -ne $script:RecoveryBatchDetails) {
                        Reset-RecoveryPlan "Sessione autenticata attiva. Il lotto e' associato ai sorgenti: eseguire la verifica remota."
                        $RecoveryConfirmationHint.Text = "Sessione attiva: verifica il lotto."
                    }
                    Add-Activity "Sessione autenticata aperta; passphrase e MFA non saranno richiesti di nuovo durante questa sessione."
                } catch {
                    $FailureMessage = [string]$_.Exception.Message
                    Stop-ImportSession "" $false
                    Reset-ImportPlan "Apertura sessione non riuscita. Nessuna credenziale e' stata conservata."
                    if ($null -ne $script:RecoveryBatchDetails) {
                        Reset-RecoveryPlan "Apertura sessione non riuscita. Il lotto resta associato, ma nessuna credenziale e' stata conservata."
                    }
                    Add-Activity "Apertura sessione non riuscita: $FailureMessage"
                    [System.Windows.MessageBox]::Show($FailureMessage, "Sessione non avviata", "OK", "Error") | Out-Null
                } finally {
                    $KeyPassphrase.Clear()
                    $MfaTotpCode.Clear()
                    Update-ImportSessionState
                }
            } `
            -OnFailure {
                param($FailureMessage, $Operation)
                Stop-ImportSession "" $false
                Reset-ImportPlan "Apertura sessione non riuscita. Nessuna credenziale e' stata conservata."
                if ($null -ne $script:RecoveryBatchDetails) {
                    Reset-RecoveryPlan "Apertura sessione non riuscita. Il lotto resta associato, ma nessuna credenziale e' stata conservata."
                }
                Add-Activity "Apertura sessione non riuscita: $FailureMessage"
                $KeyPassphrase.Clear()
                $MfaTotpCode.Clear()
                Update-ImportSessionState
                [System.Windows.MessageBox]::Show($FailureMessage, "Sessione non avviata", "OK", "Error") | Out-Null
            }
        if (-not $Started) { Stop-ImportSession "" $false }
    } catch {
        $FailureMessage = [string]$_.Exception.Message
        Stop-ImportSession "" $false
        Reset-ImportPlan "Apertura sessione non riuscita. Nessuna credenziale e' stata conservata."
        if ($null -ne $script:RecoveryBatchDetails) {
            Reset-RecoveryPlan "Apertura sessione non riuscita. Il lotto resta associato, ma nessuna credenziale e' stata conservata."
        }
        Add-Activity "Apertura sessione non riuscita: $FailureMessage"
        [System.Windows.MessageBox]::Show($FailureMessage, "Sessione non avviata", "OK", "Error") | Out-Null
    }
    $Passphrase = $null
    $MfaCode = $null
}

function Get-SecureErrorMessage($Envelope) {
    if ($null -ne $Envelope -and $null -ne $Envelope.error) {
        $Message = if ($Envelope.error.message) { [string]$Envelope.error.message } else { "Operazione protetta non riuscita." }
        $Technical = New-Object System.Collections.Generic.List[string]
        $Code = [string]$Envelope.error.code
        if ($Code -match '^[A-Z][A-Z0-9_]{0,63}$') { $Technical.Add("codice $Code") }
        $Details = $Envelope.error.details
        if ($null -ne $Details) {
            $PhaseLabels = @{
                server_key = "lettura chiave server"
                server_ownership = "verifica crittografica server"
                user_challenge = "richiesta sfida utente"
                challenge_decryption = "decifratura sfida utente"
                challenge_response = "risposta alla sfida utente"
                session_cookie = "creazione sessione"
                identity_check = "lettura identita'"
                mfa_totp = "verifica MFA TOTP"
                identity_after_mfa = "verifica sessione dopo MFA"
                identity_binding = "associazione chiave-identita'"
            }
            $Phase = [string]$Details.auth_phase
            if ($PhaseLabels.ContainsKey($Phase)) { $Technical.Add("fase $($PhaseLabels[$Phase])") }
            if ([string]$Details.http_status -match '^\d{3}$') {
                $HttpStatus = [int]$Details.http_status
                if ($HttpStatus -ge 100 -and $HttpStatus -le 599) { $Technical.Add("HTTP $HttpStatus") }
            }
            if ([string]$Details.clock_skew_seconds -match '^-?\d{1,5}$') {
                $ClockSkew = [int]$Details.clock_skew_seconds
                if ([Math]::Abs($ClockSkew) -ge 20) {
                    $Technical.Add("scarto orologio $ClockSkew s")
                    $Message += " Verificare la sincronizzazione automatica di data, ora e fuso orario sia in Windows sia sul server Passbolt."
                }
            }
        }
        if ($Technical.Count -gt 0) {
            return "$Message`n`nDettaglio tecnico sicuro: $($Technical -join ' | ')"
        }
        return $Message
    }
    return "Operazione protetta non riuscita."
}

function Get-RecoveryStatusLabel([string]$Status) {
    switch ($Status) {
        "recovery_required" { return "Recuperabile" }
        "truncated" { return "Troncato - manuale" }
        "corrupt" { return "Corrotto - manuale" }
        "complete" { return "Completato" }
        default { return "Sconosciuto" }
    }
}

function Reset-RecoveryPlan([string]$Status = "Seleziona un lotto recuperabile e associa la cartella sorgente corrente.") {
    $script:RecoveryPlan = $null
    $RecoveryMetricVerified.Text = [string][char]0x2014
    $RecoveryMetricRemoteSuccess.Text = [string][char]0x2014
    $RecoveryMetricNotApplied.Text = [string][char]0x2014
    $RecoveryMetricConflicts.Text = [string][char]0x2014
    $RecoverySafetyStatus.Text = "Nessuna cancellazione, spostamento o sovrascrittura viene pianificata dal recupero."
    $RecoverySafetyStatus.Foreground = Get-Brush "#248A3D"
    $RecoveryConfirmation.Text = ""
    $RecoveryConfirmation.IsEnabled = $false
    $RecoveryConfirmationHint.Text = "Prima esegui la verifica autenticata del lotto."
    $RecoveryStatus.Text = $Status
    Update-RecoveryActionState
}

function Clear-RecoveryCandidateState {
    $script:RecoveryBatchDetails = $null
    $script:RecoveryCandidates = @()
    $script:RecoverySecretOverrides = @{}
    $script:RecoverySourceFilePasswords = @{}
}

function Update-RecoveryActionState {
    $Selected = $RecoveryBatchesGrid.SelectedItem
    $HasSelected = $null -ne $Selected
    $Recoverable = $HasSelected -and [string]$Selected.Status -eq "recovery_required"
    $Associated = (
        $Recoverable -and
        $null -ne $script:RecoveryBatchDetails -and
        [string]$script:RecoveryBatchDetails.batch_id -eq [string]$Selected.BatchId -and
        $script:RecoveryCandidates.Count -eq [int]$Selected.CandidateCount
    )
    $SessionReady = (
        (Test-ImportSessionActive) -and
        $script:ImportSessionRoot -eq $script:InventoryFolder
    )
    $HasPlan = $null -ne $script:RecoveryPlan
    $VerifyRecoveryButton.IsEnabled = ($Associated -and $SessionReady -and -not $HasPlan)
    $ArchiveRecoveryButton.IsEnabled = ($HasSelected -and -not $HasPlan)
    $RefreshRecoveryButton.IsEnabled = -not $HasPlan
    $RecoveryBatchesGrid.IsEnabled = -not $HasPlan
    $RecoveryConfirmation.IsEnabled = $HasPlan
    $ExpectedConfirmation = if ($HasPlan) { [string]$script:RecoveryPlan.confirmation_required } else { "" }
    $ExecuteRecoveryButton.IsEnabled = (
        $HasPlan -and
        $SessionReady -and
        [bool]$script:RecoveryPlan.can_recover -and
        -not [bool]$script:RecoveryPlan.destructive_actions_planned -and
        [int]$script:RecoveryPlan.conflict_count -eq 0 -and
        $RecoveryConfirmation.Text.Trim() -eq $ExpectedConfirmation
    )
}

function Set-RecoveryBatchDetailsResult([object]$Details, [string]$ExpectedBatchId) {
    if ([string]$Details.batch_id -ne $ExpectedBatchId -or [string]$Details.status -ne "recovery_required") {
        throw "Lo stato del lotto e' cambiato. Aggiornare l'elenco."
    }
    $RowsById = @{}
    $DuplicateIds = @{}
    foreach ($Row in @($script:AllReviewRows)) {
        $CandidateId = [string]$Row.CandidateId
        if ($RowsById.ContainsKey($CandidateId)) { $DuplicateIds[$CandidateId] = $true }
        else { $RowsById[$CandidateId] = $Row }
    }
    $Candidates = New-Object System.Collections.Generic.List[object]
    $Missing = New-Object System.Collections.Generic.List[string]
    $Incomplete = New-Object System.Collections.Generic.List[string]
    $RecoveryPasswords = @{}
    $RecoveryOverrides = @{}
    foreach ($CandidateIdValue in @($Details.candidate_ids)) {
        $CandidateId = [string]$CandidateIdValue
        if (-not $RowsById.ContainsKey($CandidateId) -or $DuplicateIds.ContainsKey($CandidateId)) {
            $Missing.Add($CandidateId)
            continue
        }
        $Row = $RowsById[$CandidateId]
        if ([string]$Row.Status -ne "ready") {
            $Incomplete.Add($CandidateId)
            continue
        }
        if ([bool]$Row.SourcePasswordRequired) {
            $RelativePath = [string]$Row.SourceRelativePath
            if (-not $script:ReviewFilePasswords.ContainsKey($RelativePath) -or -not [string]$script:ReviewFilePasswords[$RelativePath]) {
                $Incomplete.Add($CandidateId)
                continue
            }
            $RecoveryPasswords[$RelativePath] = [string]$script:ReviewFilePasswords[$RelativePath]
        }
        if ([bool]$Row.PasswordOverridden) {
            if (-not [string]$Row.SecretValue) {
                $Incomplete.Add($CandidateId)
                continue
            }
            $RecoveryOverrides[$CandidateId] = [string]$Row.SecretValue
        }
        $Candidates.Add((Get-ReviewCandidateRequest $Row))
    }
    if ($Missing.Count -gt 0 -or $Incomplete.Count -gt 0 -or $Candidates.Count -ne [int]$Details.candidate_count) {
        $RecoveryStatus.Text = "Cartella non ancora associata: trovati $($Candidates.Count) di $([int]$Details.candidate_count) candidati. Torna all'inventario, rivedi tutti i documenti originali e riapplica eventuali correzioni fatte prima dell'import interrotto."
        $RecoveryConfirmationHint.Text = "Associazione sorgente incompleta."
        return
    }

    $script:RecoveryBatchDetails = $Details
    $script:RecoveryCandidates = $Candidates.ToArray()
    $script:RecoverySourceFilePasswords = $RecoveryPasswords
    $script:RecoverySecretOverrides = $RecoveryOverrides
    $PermissionRecoveryNote = if ([string]$Details.permission_mode -eq "custom") {
        " Il lotto usava una ACL personalizzata: ricreare la stessa selezione nell'editor permessi prima della verifica."
    } else {
        " Il lotto usava i permessi ereditati; impostare l'editor su Eredita dalla destinazione."
    }
    $RecoveryStatus.Text = "Lotto associato alla cartella corrente: $($Candidates.Count) candidati riletti. Server, utente, sorgenti, destinazione, permessi e stato remoto saranno verificati nella sessione autenticata.$PermissionRecoveryNote"
    $RecoveryConfirmationHint.Text = if (Test-ImportSessionActive) { "Sessione attiva: verifica il lotto." } else { "Avvia la sessione sicura, poi verifica il lotto." }
}

function Set-RecoveryBatchSelection {
    if ($script:UpdatingRecoverySelection) { return }
    Clear-RecoveryCandidateState
    Reset-RecoveryPlan
    $Selected = $RecoveryBatchesGrid.SelectedItem
    if ($null -eq $Selected) {
        $RecoveryStatus.Text = if ($script:RecoveryBatches.Count -gt 0) { "Seleziona un lotto dall'elenco." } else { "Nessun registro locale attivo." }
        Update-ImportSessionState
        return
    }

    $Status = [string]$Selected.Status
    if ($Status -eq "complete") {
        $RecoveryStatus.Text = "Il lotto e' completato e puo' essere archiviato senza cancellarne l'evidenza."
        $RecoveryConfirmationHint.Text = "Nessuna ripresa necessaria."
        Update-ImportSessionState
        return
    }
    if ($Status -eq "truncated") {
        $RecoveryStatus.Text = "L'ultima scrittura del registro e' troncata: il recupero automatico resta bloccato. Verificare manualmente Passbolt oppure archiviare il lotto come abbandonato."
        $RecoverySafetyStatus.Text = "Fail-closed: nessuna richiesta remota verra' inviata per questo registro troncato."
        $RecoverySafetyStatus.Foreground = Get-Brush "#C77D00"
        Update-ImportSessionState
        return
    }
    if ($Status -eq "corrupt") {
        $RecoveryStatus.Text = "L'integrita' del registro non e' verificabile: il recupero automatico resta bloccato. Verificare manualmente Passbolt oppure archiviare il lotto come abbandonato."
        $RecoverySafetyStatus.Text = "Fail-closed: nessuna richiesta remota verra' inviata per questo registro corrotto."
        $RecoverySafetyStatus.Foreground = Get-Brush "#D70015"
        Update-ImportSessionState
        return
    }
    if ($Status -ne "recovery_required") {
        $RecoveryStatus.Text = "Stato del lotto non supportato. Aggiornare l'elenco."
        Update-ImportSessionState
        return
    }

    $BatchId = [string]$Selected.BatchId
    $Request = [pscustomobject]@{ batch_id = $BatchId }
    $OperationParameters = @{
        Name = "Associazione journal ai sorgenti"
        Category = "read"
        WorkKind = "SecureJsonProcess"
        Payload = New-SecureJsonOperationPayload $PythonExecutable @($ImportScript, "--reconciliation-describe") $Request 30000
        Context = [pscustomobject]@{ BatchId = $BatchId }
        OnSuccess = {
            param($Envelope, $Operation)
            try {
                if (-not [bool]$Envelope.ok) { throw (Get-SecureErrorMessage $Envelope) }
                Set-RecoveryBatchDetailsResult $Envelope.result ([string]$Operation.Context.BatchId)
            } catch {
                Clear-RecoveryCandidateState
                $RecoveryStatus.Text = "Associazione del lotto non riuscita: $($_.Exception.Message)"
                $RecoveryConfirmationHint.Text = "Aggiorna l'elenco e riprova."
            }
            Update-ImportSessionState
        }
        OnFailure = {
            param($FailureMessage, $Operation)
            Clear-RecoveryCandidateState
            $RecoveryStatus.Text = "Associazione del lotto non riuscita: $FailureMessage"
            $RecoveryConfirmationHint.Text = "Aggiorna l'elenco e riprova."
            Update-ImportSessionState
        }
    }
    [void](Start-UiOperation @OperationParameters)
}
function Refresh-RecoveryBatches([switch]$Quiet, [scriptblock]$OnCompleted = $null) {
    if ($null -ne $script:RecoveryPlan) { return }
    $PreviousBatchId = if ($null -ne $RecoveryBatchesGrid.SelectedItem) { [string]$RecoveryBatchesGrid.SelectedItem.BatchId } else { "" }
    $Context = [pscustomobject]@{
        PreviousBatchId = $PreviousBatchId
        Quiet = [bool]$Quiet
        OnCompleted = $OnCompleted
    }
    $OperationParameters = @{
        Name = "Aggiornamento registri di recupero"
        Category = "read"
        WorkKind = "PythonJson"
        Payload = New-PythonJsonOperationPayload $ImportScript @("--reconciliation-list")
        Context = $Context
        OnSuccess = {
            param($Envelope, $Operation)
            if (-not [bool]$Envelope.ok) {
                $FailureMessage = Get-SecureErrorMessage $Envelope
                $script:ImportRecoveryRequired = $true
                $script:RecoveryBatches = @()
                $RecoveryBatchesGrid.ItemsSource = $null
                Clear-RecoveryCandidateState
                Reset-RecoveryPlan "Elenco dei registri non disponibile: $FailureMessage"
                Update-ImportSessionState
                if (-not [bool]$Operation.Context.Quiet) { Add-Activity "Aggiornamento registri non riuscito: $FailureMessage" }
                if ($null -ne $Operation.Context.OnCompleted) { & $Operation.Context.OnCompleted $false }
                return
            }
            $Rows = New-Object System.Collections.Generic.List[object]
            foreach ($Batch in @($Envelope.result.batches)) {
                $RecordedAtLabel = "Non disponibile"
                if ([string]$Batch.recorded_at) {
                    try { $RecordedAtLabel = ([DateTimeOffset]::Parse([string]$Batch.recorded_at)).ToLocalTime().ToString("dd/MM/yyyy HH:mm") } catch { $RecordedAtLabel = [string]$Batch.recorded_at }
                }
                $Rows.Add([pscustomobject]@{
                    BatchId = [string]$Batch.batch_id
                    Status = [string]$Batch.status
                    StatusLabel = Get-RecoveryStatusLabel ([string]$Batch.status)
                    RecordedAtLabel = $RecordedAtLabel
                    CandidateCount = if ($null -eq $Batch.candidate_count) { -1 } else { [int]$Batch.candidate_count }
                    CandidateCountLabel = if ($null -eq $Batch.candidate_count) { [string][char]0x2014 } else { [string]$Batch.candidate_count }
                    EventCount = if ($null -eq $Batch.event_count) { -1 } else { [int]$Batch.event_count }
                })
            }
            $script:RecoveryBatches = $Rows.ToArray()
            $BlockingBatches = @($script:RecoveryBatches | Where-Object { [string]$_.Status -ne "complete" })
            $script:ImportRecoveryRequired = $BlockingBatches.Count -gt 0
            $script:UpdatingRecoverySelection = $true
            try {
                $RecoveryBatchesGrid.ItemsSource = $script:RecoveryBatches
                $SelectedRow = @($script:RecoveryBatches | Where-Object { [string]$_.BatchId -eq [string]$Operation.Context.PreviousBatchId }) | Select-Object -First 1
                if ($null -eq $SelectedRow -and $script:RecoveryBatches.Count -gt 0) { $SelectedRow = $script:RecoveryBatches[0] }
                $RecoveryBatchesGrid.SelectedItem = $SelectedRow
            } finally {
                $script:UpdatingRecoverySelection = $false
            }
            Update-ImportSessionState
            if ($script:ImportRecoveryRequired -and $script:Phase04Workspace -eq "new_import") {
                Show-Phase04Workspace "recovery" -SkipRefresh
            }
            if (-not [bool]$Operation.Context.Quiet) { Add-Activity "Registri locali aggiornati: $($script:RecoveryBatches.Count) lotti attivi; nessun documento o segreto letto." }
            Update-RecoveryActionState
            if ($null -ne $Operation.Context.OnCompleted) {
                & $Operation.Context.OnCompleted $true
            } else {
                Set-RecoveryBatchSelection
            }
        }
        OnFailure = {
            param($FailureMessage, $Operation)
            $script:ImportRecoveryRequired = $true
            $script:RecoveryBatches = @()
            $RecoveryBatchesGrid.ItemsSource = $null
            Clear-RecoveryCandidateState
            Reset-RecoveryPlan "Elenco dei registri non disponibile: $FailureMessage"
            Update-ImportSessionState
            if (-not [bool]$Operation.Context.Quiet) { Add-Activity "Aggiornamento registri non riuscito: $FailureMessage" }
            if ($null -ne $Operation.Context.OnCompleted) { & $Operation.Context.OnCompleted $false }
        }
    }
    [void](Start-UiOperation @OperationParameters)
}
function Invoke-ArchiveRecoveryBatch([switch]$AlreadyConfirmed) {
    $Selected = $RecoveryBatchesGrid.SelectedItem
    if ($null -eq $Selected -or $null -ne $script:RecoveryPlan) { return }
    $Status = [string]$Selected.Status
    $StatusText = Get-RecoveryStatusLabel $Status
    if (-not $AlreadyConfirmed) {
        $Warning = if ($Status -eq "complete") {
            "Il registro completato verra' spostato nell'archivio locale. L'evidenza non sara' cancellata. Continuare?"
        } else {
            "Il lotto $StatusText verra' marcato come abbandonato e spostato nell'archivio locale. L'evidenza non sara' cancellata, ma non comparira' piu tra i recuperi attivi. Continuare?"
        }
        $Decision = [System.Windows.MessageBox]::Show($Warning, "Archivia lotto", "YesNo", "Warning")
        if ([string]$Decision -ne "Yes") { return }
    }

    $BatchId = [string]$Selected.BatchId
    $ArchiveRequest = [pscustomobject]@{
        batch_id = $BatchId
        expected_status = $Status
        confirmation = "ARCHIVIA $BatchId"
    }
    $OperationParameters = @{
        Name = "Archiviazione journal di recupero"
        Category = "write"
        WorkKind = "SecureJsonProcess"
        Payload = New-SecureJsonOperationPayload $PythonExecutable @($ImportScript, "--reconciliation-archive") $ArchiveRequest 30000
        Context = [pscustomobject]@{ BatchId = $BatchId; Status = $Status }
        OnSuccess = {
            param($Envelope, $Operation)
            if (-not [bool]$Envelope.ok) {
                $FailureMessage = Get-SecureErrorMessage $Envelope
                Add-Activity "Archiviazione del lotto non riuscita: $FailureMessage"
                Update-RecoveryActionState
                [System.Windows.MessageBox]::Show($FailureMessage, "Archiviazione non riuscita", "OK", "Error") | Out-Null
                return
            }
            Clear-RecoveryCandidateState
            Reset-RecoveryPlan "Lotto archiviato senza cancellarne l'evidenza locale."
            Add-Activity "Registro locale $([string]$Operation.Context.BatchId) archiviato dallo stato $([string]$Operation.Context.Status); nessuna evidenza eliminata."
            [System.Windows.MessageBox]::Show("Lotto archiviato correttamente. Il journal e' stato spostato, non cancellato.", "Archiviazione completata", "OK", "Information") | Out-Null
            Refresh-RecoveryBatches -Quiet
        }
        OnFailure = {
            param($FailureMessage, $Operation)
            Add-Activity "Archiviazione del lotto non riuscita: $FailureMessage"
            Update-RecoveryActionState
            [System.Windows.MessageBox]::Show($FailureMessage, "Archiviazione non riuscita", "OK", "Error") | Out-Null
        }
    }
    [void](Start-UiOperation @OperationParameters)
}
function Reset-ImportOperationalViews {
    $script:ImportDashboard = $null
    $ExportPreflightReceiptButton.IsEnabled = $false
    $ExportMigrationReceiptButton.IsEnabled = $false
    $PreflightGrid.ItemsSource = $null
    $PreflightStatus.Text = "Eseguire il preflight autenticato per controllare compatibilita', destinazione e permessi."
    $PreflightStatus.Foreground = Get-Brush "#355E85"
    $VerificationGrid.ItemsSource = $null
    $VerificationStatus.Text = "Dopo l'importazione, ogni risorsa verra' riletta e confrontata senza conservare password o hash dei segreti."
    $VerificationStatus.Foreground = Get-Brush "#355E85"
    $BatchPhase.Text = "Lotto non avviato"
    $BatchCurrentOperation.Text = "Gli eventi compariranno qui durante l'importazione."
    $BatchProgressText.Text = "0%"
    $BatchProgressBar.Value = 0
    $BatchMetricCompleted.Text = "0 / 0"
    $BatchMetricCreated.Text = "0"
    $BatchMetricVerified.Text = "0"
    $BatchMetricErrors.Text = "0"
    $BatchElapsed.Text = "00:00"
    $BatchEta.Text = [string][char]0x2014
    $BatchActivityGrid.ItemsSource = $null
}

function Get-ImportDurationLabel([TimeSpan]$Duration) {
    if ($Duration.TotalHours -ge 1) { return "{0:00}:{1:00}:{2:00}" -f [int]$Duration.TotalHours, $Duration.Minutes, $Duration.Seconds }
    return "{0:00}:{1:00}" -f $Duration.Minutes, $Duration.Seconds
}

function Update-ImportDashboardMetrics {
    if ($null -eq $script:ImportDashboard) { return }
    $Dashboard = $script:ImportDashboard
    $Elapsed = [DateTime]::UtcNow - $Dashboard.StartedUtc
    $Completed = $Dashboard.CompletedCandidateIds.Count
    $WorkDone = $Completed + $Dashboard.CreatedCandidateIds.Count + $Dashboard.CompletedFolderIds.Count
    $Percent = if ($Dashboard.TotalWorkUnits -gt 0) {
        [Math]::Min(100, [Math]::Round(($WorkDone * 100.0) / $Dashboard.TotalWorkUnits))
    } else { 0 }
    if ($Dashboard.Finished) { $Percent = 100 }
    $BatchProgressBar.Value = $Percent
    $BatchProgressText.Text = "$Percent%"
    $BatchMetricCompleted.Text = "$Completed / $($Dashboard.TotalCandidates)"
    $BatchMetricCreated.Text = [string]$Dashboard.CreatedCandidateIds.Count
    $BatchMetricVerified.Text = [string]$Dashboard.VerifiedCandidateIds.Count
    $BatchMetricErrors.Text = [string]$Dashboard.ErrorCount
    $BatchElapsed.Text = Get-ImportDurationLabel $Elapsed
    if (-not $Dashboard.Finished -and $WorkDone -gt 0 -and $WorkDone -lt $Dashboard.TotalWorkUnits) {
        $SecondsPerUnit = $Elapsed.TotalSeconds / $WorkDone
        $Remaining = [TimeSpan]::FromSeconds([Math]::Max(0, $SecondsPerUnit * ($Dashboard.TotalWorkUnits - $WorkDone)))
        $BatchEta.Text = Get-ImportDurationLabel $Remaining
    } elseif ($Dashboard.Finished) {
        $BatchEta.Text = "00:00"
    } else {
        $BatchEta.Text = [string][char]0x2014
    }
}

function Add-ImportDashboardEvent(
    [string]$Phase,
    [string]$ObjectLabel,
    [string]$Status
) {
    if ($null -eq $script:ImportDashboard) { return }
    $Activity = $script:ImportDashboard.Activity
    $Activity.Add([pscustomobject]@{
        Time = Get-Date -Format "HH:mm:ss"
        Phase = $Phase
        Object = $ObjectLabel
        Status = $Status
    })
    while ($Activity.Count -gt 300) { $Activity.RemoveAt(0) }
    if ($Activity.Count -gt 0) {
        try { $BatchActivityGrid.ScrollIntoView($Activity[$Activity.Count - 1]) } catch {}
    }
}

function Initialize-ImportDashboard([int]$CreateCount, [int]$DuplicateCount, [int]$FolderOperationCount = 0) {
    $TitleByCandidate = @{}
    foreach ($Candidate in @($script:ImportCandidates)) {
        $TitleByCandidate[[string]$Candidate.candidate_id] = [string]$Candidate.title
    }
    $Activity = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
    $script:ImportDashboard = [pscustomobject]@{
        StartedUtc = [DateTime]::UtcNow
        TotalCandidates = $CreateCount + $DuplicateCount
        TotalWorkUnits = ($CreateCount * 2) + $DuplicateCount + $FolderOperationCount
        CreatedCandidateIds = New-Object 'System.Collections.Generic.HashSet[string]'
        VerifiedCandidateIds = New-Object 'System.Collections.Generic.HashSet[string]'
        CompletedCandidateIds = New-Object 'System.Collections.Generic.HashSet[string]'
        CompletedFolderIds = New-Object 'System.Collections.Generic.HashSet[string]'
        TitleByCandidate = $TitleByCandidate
        ErrorCount = 0
        Finished = $false
        Activity = $Activity
    }
    $BatchActivityGrid.ItemsSource = $Activity
    $BatchPhase.Text = "Preparazione del lotto"
    $BatchCurrentOperation.Text = "Il journal locale e' pronto; attesa della prima operazione Passbolt."
    $ImportWorkspaceTabs.SelectedIndex = 3
    Add-ImportDashboardEvent "Preparazione" "Lotto" "Avvio confermato"
    Update-ImportDashboardMetrics
}

function Get-ImportDashboardObjectLabel([object]$Payload) {
    $CandidateId = [string]$Payload.candidate_id
    if ($CandidateId -and $null -ne $script:ImportDashboard -and $script:ImportDashboard.TitleByCandidate.ContainsKey($CandidateId)) {
        return [string]$script:ImportDashboard.TitleByCandidate[$CandidateId]
    }
    if ([string]$Payload.object_type -eq "folder" -or -not [string]::IsNullOrWhiteSpace([string]$Payload.folder_id)) { return "Cartella" }
    if ([string]$Payload.object_type -eq "resource" -or -not [string]::IsNullOrWhiteSpace([string]$Payload.resource_id)) { return "Risorsa" }
    return "Lotto"
}

function Update-ImportDashboardProgress([object]$Envelope) {
    if ($null -eq $script:ImportDashboard -or [string]$Envelope.type -ne "progress") { return }
    $EventType = [string]$Envelope.event_type
    $Payload = $Envelope.payload
    $ObjectLabel = Get-ImportDashboardObjectLabel $Payload
    $Phase = "Scrittura"
    $Status = $EventType
    switch ($EventType) {
        "operation_intent" {
            $Phase = if ([string]$Payload.object_type -eq "folder") { "Cartelle" } else { "Risorse" }
            $Status = switch ([string]$Payload.action) {
                "create_folder" { "Creazione in corso" }
                "share_folder" { "Applicazione permessi" }
                "reconcile_folder" { "Riconciliazione permessi" }
                "create_resource" { "Creazione in corso" }
                "share_resource" { "Condivisione in corso" }
                default { "Operazione in corso" }
            }
        }
        "folder_created" {
            $Phase = "Cartelle"; $Status = "Creata"
            [void]$script:ImportDashboard.CompletedFolderIds.Add([string]$Payload.folder_id)
        }
        "folder_shared" {
            $Phase = "Cartelle"; $Status = "Permessi applicati"
            [void]$script:ImportDashboard.CompletedFolderIds.Add([string]$Payload.folder_id)
        }
        "resource_created" {
            $Phase = "Risorse"; $Status = "Creata"
            [void]$script:ImportDashboard.CreatedCandidateIds.Add([string]$Payload.candidate_id)
        }
        "resource_shared" { $Phase = "Risorse"; $Status = "Condivisa" }
        "resource_verified" {
            $Phase = "Verifica finale"; $Status = "Metadati, contenuto, cartella e ACL verificati"
            [void]$script:ImportDashboard.VerifiedCandidateIds.Add([string]$Payload.candidate_id)
            [void]$script:ImportDashboard.CompletedCandidateIds.Add([string]$Payload.candidate_id)
        }
        "duplicate_skipped" {
            $Phase = "Duplicati"; $Status = "Saltato in sicurezza"
            [void]$script:ImportDashboard.CompletedCandidateIds.Add([string]$Payload.candidate_id)
        }
        "operation_failed" {
            $Phase = "Errore"; $Status = "Operazione non completata ($([string]$Payload.error_code))"
            $script:ImportDashboard.ErrorCount++
        }
        "batch_completed" {
            $Phase = "Completamento"; $Status = "Journal chiuso dopo la verifica"
            $script:ImportDashboard.Finished = $true
            $BatchPhase.Text = "Lotto completato e verificato"
        }
    }
    if ($EventType -ne "batch_completed") { $BatchPhase.Text = $Phase }
    $BatchCurrentOperation.Text = "$ObjectLabel - $Status"
    Add-ImportDashboardEvent $Phase $ObjectLabel $Status
    Update-ImportDashboardMetrics
}

function Set-ImportDashboardFailure([string]$Message) {
    if ($null -eq $script:ImportDashboard) { return }
    if ($script:ImportDashboard.ErrorCount -eq 0) { $script:ImportDashboard.ErrorCount = 1 }
    $BatchPhase.Text = "Lotto interrotto: verifica richiesta"
    $BatchCurrentOperation.Text = $Message
    Add-ImportDashboardEvent "Errore" "Lotto" "Interrotto; usare il recupero guidato"
    Update-ImportDashboardMetrics
}

function Reset-ImportPlan([string]$Status = "Eseguire il dry-run per preparare un nuovo piano.") {
    $script:ImportPlan = $null
    $script:ImportPlanKeyPath = ""
    $script:PreflightReceiptEvidence = $null
    $script:MigrationReceiptEvidence = $null
    $ExportPreflightReceiptButton.IsEnabled = $false
    $ExportMigrationReceiptButton.IsEnabled = $false
    $script:ImportCompleted = $false
    $ImportPlanGrid.ItemsSource = $null
    $ImportMetricCreate.Text = [string][char]0x2014
    $ImportMetricDuplicates.Text = [string][char]0x2014
    $ImportMetricExisting.Text = [string][char]0x2014
    $ImportIdentity.Text = Get-ImportSessionIdentityText
    $ImportPlanStatus.Text = $Status
    $ImportConfirmation.Text = ""
    $ImportConfirmation.IsEnabled = $false
    $ConfirmationHint.Text = if (Test-ImportSessionActive) { "Sessione attiva: eseguire il dry-run." } else { "Prima avviare la sessione sicura." }
    $ExecuteImportButton.IsEnabled = $false
}

function Get-SelectedDestinationFolderId {
    if ($null -eq $DestinationFolder.SelectedItem) { return "" }
    return [string]$DestinationFolder.SelectedItem.Tag
}

function Get-PermissionTemplatePayload {
    $Entries = New-Object System.Collections.Generic.List[object]
    foreach ($Entry in @($script:PermissionTemplate)) {
        $Entries.Add([pscustomobject][ordered]@{
            aro = [string]$Entry.aro
            aro_foreign_key = [string]$Entry.aro_foreign_key
            type = [int]$Entry.type
        })
    }
    return $Entries.ToArray()
}

function Get-PermissionLevelLabel([int]$PermissionType) {
    switch ($PermissionType) {
        1 { return "Lettura" }
        7 { return "Aggiornamento" }
        15 { return "Proprietario" }
        default { return "Non valido" }
    }
}

function Update-PermissionEditorState {
    $ConfigurePermissionsButton.IsEnabled = Test-ImportSessionActive
    if ($script:PermissionMode -eq "custom") {
        $PermissionModeStatus.Text = "Personalizzati: $(@($script:PermissionTemplate).Count) utenti/gruppi + proprietario autenticato"
        $PermissionModeStatus.Foreground = Get-Brush "#248A3D"
    } else {
        $PermissionModeStatus.Text = "Ereditati dalla destinazione"
        $PermissionModeStatus.Foreground = Get-Brush "#6E6E73"
    }
}

function Show-PermissionEditor(
    [switch]$BuildOnly,
    [switch]$AclPlanMode,
    [object[]]$InitialPermissions = @(),
    [string]$TargetPath = "",
    [object]$CatalogResult = $null
) {
    if ($BuildOnly) {
        $CatalogResult = [pscustomobject]@{
            entries = @($script:PermissionCatalog)
            owner = if ($null -ne $script:ImportSessionInfo) { $script:ImportSessionInfo.user } else { $null }
        }
    } elseif ($null -eq $CatalogResult) {
        throw "Il catalogo permessi deve essere caricato fuori dal thread UI prima di aprire l'editor."
    }

    $CatalogRows = New-Object System.Collections.ArrayList
    foreach ($Entry in @($CatalogResult.entries)) {
        $Availability = if ([bool]$Entry.available) { "" } else { " [non disponibile]" }
        [void]$CatalogRows.Add([pscustomobject]@{
            Aro = [string]$Entry.aro
            Id = [string]$Entry.aro_foreign_key
            SubjectType = [string]$Entry.subject_type
            DisplayName = [string]$Entry.display_name
            Detail = [string]$Entry.detail
            Available = [bool]$Entry.available
            UnavailableReason = [string]$Entry.unavailable_reason
            Label = "[$([string]$Entry.subject_type)] $([string]$Entry.display_name) - $([string]$Entry.detail)$Availability"
        })
    }
    $SelectedRows = New-Object System.Collections.ArrayList
    $SeedPermissions = if ($AclPlanMode) { @($InitialPermissions) } else { @($script:PermissionTemplate) }
    foreach ($Permission in $SeedPermissions) {
        $CatalogEntry = @($CatalogRows | Where-Object { $_.Aro -eq [string]$Permission.aro -and $_.Id -eq [string]$Permission.aro_foreign_key }) | Select-Object -First 1
        $Subject = if ($null -ne $CatalogEntry) { "[$($CatalogEntry.SubjectType)] $($CatalogEntry.DisplayName)" } else { "[$([string]$Permission.aro)] $([string]$Permission.aro_foreign_key) [non disponibile]" }
        [void]$SelectedRows.Add([pscustomobject]@{
            Aro = [string]$Permission.aro
            Id = [string]$Permission.aro_foreign_key
            Subject = $Subject
            PermissionType = [int]$Permission.type
            PermissionLabel = Get-PermissionLevelLabel ([int]$Permission.type)
        })
    }

    $Dialog = New-Object System.Windows.Window
    $Dialog.Title = if ($AclPlanMode) { "Dry-run ACL esistente - Passbolt" } else { "Editor permessi - Passbolt" }
    $Dialog.Width = 980
    $Dialog.Height = 650
    $Dialog.MinWidth = 820
    $Dialog.MinHeight = 520
    $Dialog.WindowStartupLocation = "CenterOwner"
    if (-not $BuildOnly -and $Window.IsVisible) { $Dialog.Owner = $Window }
    Initialize-ModernDialog $Dialog

    $Layout = New-Object System.Windows.Controls.Grid
    $Layout.Margin = [System.Windows.Thickness]::new(20)
    foreach ($Height in @("Auto", "Auto", "*", "Auto")) {
        $Row = New-Object System.Windows.Controls.RowDefinition
        $Row.Height = if ($Height -eq "*") { [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) } else { [System.Windows.GridLength]::Auto }
        [void]$Layout.RowDefinitions.Add($Row)
    }

    $Header = New-Object System.Windows.Controls.StackPanel
    $Title = New-Object System.Windows.Controls.TextBlock
    $Title.Text = if ($AclPlanMode) { "Simula la ACL desiderata" } else { "Permessi per nuove cartelle e risorse" }
    $Title.FontSize = 20
    $Title.FontWeight = "Bold"
    $Title.Foreground = Get-Brush "#1F2933"
    [void]$Header.Children.Add($Title)
    $Description = New-Object System.Windows.Controls.TextBlock
    $Description.Text = if ($AclPlanMode) {
        "Oggetto: $TargetPath`nModifica la selezione per costruire un confronto prima/dopo. Il proprietario autenticato resta Proprietario. Questo editor calcola esclusivamente un piano read-only: non applica alcuna modifica a Passbolt."
    } else {
        "La ACL personalizzata viene applicata solo agli oggetti creati dall'import. Il proprietario autenticato resta sempre Proprietario e non puo' essere rimosso. Gli oggetti esistenti non vengono modificati: se la loro ACL e' diversa, il dry-run blocca l'importazione."
    }
    $Description.TextWrapping = "Wrap"
    $Description.Foreground = Get-Brush "#66737F"
    $Description.Margin = [System.Windows.Thickness]::new(0, 5, 0, 0)
    [void]$Header.Children.Add($Description)
    [System.Windows.Controls.Grid]::SetRow($Header, 0)
    [void]$Layout.Children.Add($Header)

    $ModePanel = New-Object System.Windows.Controls.StackPanel
    $ModePanel.Orientation = "Horizontal"
    $ModePanel.Margin = [System.Windows.Thickness]::new(0, 14, 0, 12)
    $InheritedRadio = New-Object System.Windows.Controls.RadioButton
    $InheritedRadio.Content = "Eredita dalla destinazione"
    $InheritedRadio.GroupName = "PermissionMode"
    $InheritedRadio.IsChecked = (-not $AclPlanMode -and $script:PermissionMode -ne "custom")
    $InheritedRadio.Margin = [System.Windows.Thickness]::new(0, 0, 22, 0)
    $CustomRadio = New-Object System.Windows.Controls.RadioButton
    $CustomRadio.Content = "Usa ACL personalizzata"
    $CustomRadio.GroupName = "PermissionMode"
    $CustomRadio.IsChecked = ($AclPlanMode -or $script:PermissionMode -eq "custom")
    if ($AclPlanMode) {
        $ReadOnlyNotice = New-Object System.Windows.Controls.TextBlock
        $ReadOnlyNotice.Text = "DRY-RUN: sono consentite anche riduzioni e revoche nel piano, ma nessuna richiesta HTTP di scrittura verra' inviata."
        $ReadOnlyNotice.Foreground = Get-Brush "#B7791F"
        $ReadOnlyNotice.FontWeight = "SemiBold"
        $ReadOnlyNotice.TextWrapping = "Wrap"
        [void]$ModePanel.Children.Add($ReadOnlyNotice)
    } else {
        [void]$ModePanel.Children.Add($InheritedRadio)
        [void]$ModePanel.Children.Add($CustomRadio)
    }
    [System.Windows.Controls.Grid]::SetRow($ModePanel, 1)
    [void]$Layout.Children.Add($ModePanel)

    $Content = New-Object System.Windows.Controls.Grid
    $LeftColumn = New-Object System.Windows.Controls.ColumnDefinition
    $LeftColumn.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $RightColumn = New-Object System.Windows.Controls.ColumnDefinition
    $RightColumn.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    [void]$Content.ColumnDefinitions.Add($LeftColumn)
    [void]$Content.ColumnDefinitions.Add($RightColumn)
    [System.Windows.Controls.Grid]::SetRow($Content, 2)

    $AvailablePanel = New-Object System.Windows.Controls.DockPanel
    $AvailablePanel.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0)
    $AvailableTitle = New-Object System.Windows.Controls.TextBlock
    $AvailableTitle.Text = "Directory autenticata utenti e gruppi"
    $AvailableTitle.FontWeight = "SemiBold"
    $AvailableTitle.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    [System.Windows.Controls.DockPanel]::SetDock($AvailableTitle, "Top")
    [void]$AvailablePanel.Children.Add($AvailableTitle)
    $AddPanel = New-Object System.Windows.Controls.StackPanel
    $AddPanel.Orientation = "Horizontal"
    $AddPanel.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
    [System.Windows.Controls.DockPanel]::SetDock($AddPanel, "Bottom")
    $PermissionLevel = New-Object System.Windows.Controls.ComboBox
    $PermissionLevel.Width = 170
    foreach ($Type in @(1, 7, 15)) {
        $Item = New-Object System.Windows.Controls.ComboBoxItem
        $Item.Content = Get-PermissionLevelLabel $Type
        $Item.Tag = $Type
        [void]$PermissionLevel.Items.Add($Item)
    }
    $PermissionLevel.SelectedIndex = 0
    $AddButton = New-Object System.Windows.Controls.Button
    $AddButton.Content = "Aggiungi / aggiorna"
    $AddButton.Padding = [System.Windows.Thickness]::new(14, 7, 14, 7)
    $AddButton.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
    [void]$AddPanel.Children.Add($PermissionLevel)
    [void]$AddPanel.Children.Add($AddButton)
    [void]$AvailablePanel.Children.Add($AddPanel)
    $DirectoryList = New-Object System.Windows.Controls.ListBox
    $DirectoryList.ItemsSource = $CatalogRows
    $DirectoryList.DisplayMemberPath = "Label"
    [void]$AvailablePanel.Children.Add($DirectoryList)
    [System.Windows.Controls.Grid]::SetColumn($AvailablePanel, 0)
    [void]$Content.Children.Add($AvailablePanel)

    $SelectedPanel = New-Object System.Windows.Controls.DockPanel
    $SelectedPanel.Margin = [System.Windows.Thickness]::new(6, 0, 0, 0)
    $SelectedTitle = New-Object System.Windows.Controls.TextBlock
    $SelectedTitle.Text = if ($AclPlanMode) { "ACL desiderata (oltre al proprietario autenticato)" } else { "ACL selezionata (oltre al proprietario autenticato)" }
    $SelectedTitle.FontWeight = "SemiBold"
    $SelectedTitle.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    [System.Windows.Controls.DockPanel]::SetDock($SelectedTitle, "Top")
    [void]$SelectedPanel.Children.Add($SelectedTitle)
    $RemoveButton = New-Object System.Windows.Controls.Button
    $RemoveButton.Content = "Rimuovi selezionato"
    $RemoveButton.Padding = [System.Windows.Thickness]::new(14, 7, 14, 7)
    $RemoveButton.HorizontalAlignment = "Right"
    $RemoveButton.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
    [System.Windows.Controls.DockPanel]::SetDock($RemoveButton, "Bottom")
    [void]$SelectedPanel.Children.Add($RemoveButton)
    $SelectedGrid = New-Object System.Windows.Controls.DataGrid
    $SelectedGrid.AutoGenerateColumns = $false
    $SelectedGrid.IsReadOnly = $true
    $SelectedGrid.SelectionMode = "Single"
    $SubjectColumn = New-Object System.Windows.Controls.DataGridTextColumn
    $SubjectColumn.Header = "Utente / gruppo"
    $SubjectColumn.Binding = New-Object System.Windows.Data.Binding("Subject")
    $SubjectColumn.Width = [System.Windows.Controls.DataGridLength]::new(1, [System.Windows.Controls.DataGridLengthUnitType]::Star)
    [void]$SelectedGrid.Columns.Add($SubjectColumn)
    $LevelColumn = New-Object System.Windows.Controls.DataGridTextColumn
    $LevelColumn.Header = "Livello"
    $LevelColumn.Binding = New-Object System.Windows.Data.Binding("PermissionLabel")
    $LevelColumn.Width = 130
    [void]$SelectedGrid.Columns.Add($LevelColumn)
    $SelectedGrid.ItemsSource = $SelectedRows
    [void]$SelectedPanel.Children.Add($SelectedGrid)
    [System.Windows.Controls.Grid]::SetColumn($SelectedPanel, 1)
    [void]$Content.Children.Add($SelectedPanel)
    [void]$Layout.Children.Add($Content)

    $SetEditorEnabled = {
        $Enabled = [bool]$CustomRadio.IsChecked
        $DirectoryList.IsEnabled = $Enabled
        $PermissionLevel.IsEnabled = $Enabled
        $AddButton.IsEnabled = $Enabled
        $SelectedGrid.IsEnabled = $Enabled
        $RemoveButton.IsEnabled = $Enabled
    }
    $CustomRadio.Add_Checked($SetEditorEnabled)
    $InheritedRadio.Add_Checked($SetEditorEnabled)
    & $SetEditorEnabled

    $AddButton.Add_Click({
        $Subject = $DirectoryList.SelectedItem
        if ($null -eq $Subject) { return }
        if (-not [bool]$Subject.Available) {
            $Reason = if ([string]$Subject.UnavailableReason) { [string]$Subject.UnavailableReason } else { "Il destinatario non possiede una chiave pubblica verificabile." }
            [System.Windows.MessageBox]::Show($Reason, "Destinatario non disponibile", "OK", "Warning") | Out-Null
            return
        }
        $Type = [int]$PermissionLevel.SelectedItem.Tag
        $Existing = @($SelectedRows | Where-Object { $_.Aro -eq $Subject.Aro -and $_.Id -eq $Subject.Id }) | Select-Object -First 1
        if ($null -ne $Existing) {
            $Existing.PermissionType = $Type
            $Existing.PermissionLabel = Get-PermissionLevelLabel $Type
        } else {
            [void]$SelectedRows.Add([pscustomobject]@{
                Aro = [string]$Subject.Aro
                Id = [string]$Subject.Id
                Subject = "[$($Subject.SubjectType)] $($Subject.DisplayName)"
                PermissionType = $Type
                PermissionLabel = Get-PermissionLevelLabel $Type
            })
        }
        $SelectedGrid.Items.Refresh()
    })
    $RemoveButton.Add_Click({
        if ($null -eq $SelectedGrid.SelectedItem) { return }
        [void]$SelectedRows.Remove($SelectedGrid.SelectedItem)
        $SelectedGrid.Items.Refresh()
    })

    $Footer = New-Object System.Windows.Controls.StackPanel
    $Footer.Orientation = "Horizontal"
    $Footer.HorizontalAlignment = "Right"
    $Footer.Margin = [System.Windows.Thickness]::new(0, 14, 0, 0)
    [System.Windows.Controls.Grid]::SetRow($Footer, 3)
    $CancelButton = New-Object System.Windows.Controls.Button
    $CancelButton.Content = "Annulla"
    $CancelButton.Padding = [System.Windows.Thickness]::new(18, 8, 18, 8)
    $CancelButton.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $CancelButton.Add_Click({ $Dialog.DialogResult = $false })
    [void]$Footer.Children.Add($CancelButton)
    $SaveButton = New-Object System.Windows.Controls.Button
    $SaveButton.Content = if ($AclPlanMode) { "Calcola dry-run" } else { "Salva permessi" }
    $SaveButton.Padding = [System.Windows.Thickness]::new(18, 8, 18, 8)
    $SaveButton.Style = $Window.FindResource("PrimaryButton")
    $SaveButton.Foreground = Get-Brush "#FFFFFF"
    $SaveButton.BorderThickness = [System.Windows.Thickness]::new(0)
    $SaveButton.Add_Click({
        if (-not $AclPlanMode -and [bool]$CustomRadio.IsChecked -and $SelectedRows.Count -lt 1) {
            [System.Windows.MessageBox]::Show("Selezionare almeno un utente o gruppo, oppure usare i permessi ereditati.", "ACL incompleta", "OK", "Warning") | Out-Null
            return
        }
        if ([bool]$CustomRadio.IsChecked) {
            foreach ($Selected in @($SelectedRows)) {
                $Available = @($CatalogRows | Where-Object { $_.Aro -eq $Selected.Aro -and $_.Id -eq $Selected.Id -and $_.Available }) | Select-Object -First 1
                if ($null -eq $Available) {
                    [System.Windows.MessageBox]::Show("Rimuovere i destinatari non piu' disponibili prima di salvare.", "ACL non applicabile", "OK", "Warning") | Out-Null
                    return
                }
            }
        }
        $Dialog.Tag = [pscustomobject]@{
            Mode = if ([bool]$CustomRadio.IsChecked) { "custom" } else { "inherited" }
            Entries = @($SelectedRows)
        }
        $Dialog.DialogResult = $true
    })
    [void]$Footer.Children.Add($SaveButton)
    [void]$Layout.Children.Add($Footer)
    $Dialog.Content = $Layout

    if ($BuildOnly) {
        return [pscustomobject]@{ Window = $Dialog; SelectedGrid = $SelectedGrid; DirectoryList = $DirectoryList; PlanMode = [bool]$AclPlanMode }
    }
    if ($Dialog.ShowDialog() -ne $true) { return }
    $Result = $Dialog.Tag
    if ($AclPlanMode) {
        return [pscustomobject]@{
            Entries = @($Result.Entries | ForEach-Object {
                [pscustomobject][ordered]@{
                    aro = [string]$_.Aro
                    aro_foreign_key = [string]$_.Id
                    type = [int]$_.PermissionType
                }
            })
        }
    }
    $script:PermissionMode = [string]$Result.Mode
    if ($script:PermissionMode -eq "custom") {
        $script:PermissionTemplate = @($Result.Entries | ForEach-Object {
            [pscustomobject][ordered]@{
                aro = [string]$_.Aro
                aro_foreign_key = [string]$_.Id
                type = [int]$_.PermissionType
            }
        })
    } else {
        $script:PermissionTemplate = @()
    }
    Reset-ImportPlan "Permessi modificati. Ripetere il dry-run autenticato."
    if ($null -ne $script:RecoveryBatchDetails) {
        Reset-RecoveryPlan "Permessi modificati. Ripetere la verifica autenticata del lotto."
    }
    Update-PermissionEditorState
    Add-Activity "Configurazione permessi aggiornata: $($script:PermissionMode), $(@($script:PermissionTemplate).Count) destinatari espliciti."
}

function Open-PermissionEditorAsync(
    [switch]$AclPlanMode,
    [object[]]$InitialPermissions = @(),
    [string]$TargetPath = "",
    [scriptblock]$OnCompleted = $null,
    [object]$CallbackContext = $null
) {
    if (-not (Test-ImportSessionActive)) {
        [System.Windows.MessageBox]::Show("Avviare prima la sessione autenticata Passbolt.", "Permessi non disponibili", "OK", "Error") | Out-Null
        return
    }
    $Request = [pscustomobject][ordered]@{
        command = "session-permissions"
        session_id = $script:ImportSessionId
    }
    $OperationParameters = @{
        Name = "Caricamento catalogo permessi"
        Category = "verify"
        WorkKind = "ImportSessionJson"
        Payload = New-ImportSessionOperationPayload $Request
        Context = [pscustomobject]@{
            AclPlanMode = [bool]$AclPlanMode
            InitialPermissions = @($InitialPermissions)
            TargetPath = $TargetPath
            OnCompleted = $OnCompleted
            CallbackContext = $CallbackContext
        }
        OnSuccess = {
            param($Envelope, $Operation)
            try {
                if (-not [bool]$Envelope.ok) { throw (Get-SecureErrorMessage $Envelope) }
                if ([string]$Envelope.result.command -ne "permission-catalog") { throw "Passbolt non ha restituito un catalogo permessi valido." }
                $script:PermissionCatalog = @($Envelope.result.entries)
                $script:PermissionCatalogSessionId = $script:ImportSessionId
                $EditorResult = Show-PermissionEditor `
                    -AclPlanMode:([bool]$Operation.Context.AclPlanMode) `
                    -InitialPermissions @($Operation.Context.InitialPermissions) `
                    -TargetPath ([string]$Operation.Context.TargetPath) `
                    -CatalogResult $Envelope.result
                if ($null -ne $Operation.Context.OnCompleted) {
                    & $Operation.Context.OnCompleted $EditorResult $Operation.Context.CallbackContext
                }
            } catch {
                [System.Windows.MessageBox]::Show($_.Exception.Message, "Permessi non disponibili", "OK", "Error") | Out-Null
            }
        }
        OnFailure = {
            param($FailureMessage, $Operation)
            [System.Windows.MessageBox]::Show($FailureMessage, "Permessi non disponibili", "OK", "Error") | Out-Null
        }
    }
    [void](Start-UiOperation @OperationParameters)
}

function Get-AclInspectionStatusLabel([string]$Status) {
    switch ($Status) {
        "verified" { return "Verificata" }
        "warning" { return "Con avvisi" }
        "incomplete" { return "Incompleta" }
        default { return "Non disponibile" }
    }
}

function Reset-AclPlan([string]$Message = "Nessun piano calcolato. Seleziona un oggetto verificato di cui sei Proprietario.") {
    $script:AclPlan = $null
    $AclPlanGrid.ItemsSource = $null
    $AclPlanSummary.Text = $Message
    $AclPlanSummary.ToolTip = $null
    $AclDetailTabs.SelectedIndex = 0
    $AclConfirmation.Text = ""
    $AclConfirmation.IsEnabled = $false
    $ApplyAclButton.IsEnabled = $false
    $ApplyAclButton.ToolTip = "Calcolare prima un piano ACL applicabile."
}

function Update-AclApplyActionState {
    $Active = Test-ImportSessionActive
    $RecoverAclButton.IsEnabled = $Active
    if ($script:AclRecoveryRequired) {
        $AclConfirmation.IsEnabled = $false
        $ApplyAclButton.IsEnabled = $false
        $ApplyAclButton.ToolTip = "Recupero obbligatorio: verificare o gestire i journal ACL locali prima di applicare un piano."
        return
    }
    $Eligible = $Active -and $null -ne $script:AclPlan -and [bool]$script:AclPlan.apply_available
    $AclConfirmation.IsEnabled = $Eligible
    if (-not $Eligible) {
        $ApplyAclButton.IsEnabled = $false
        $ApplyAclButton.ToolTip = "Il piano non contiene modifiche applicabili."
        return
    }
    $Required = [string]$script:AclPlan.confirmation_required
    $ApplyAclButton.IsEnabled = ([string]$AclConfirmation.Text -ceq $Required)
    $ApplyAclButton.ToolTip = "Conferma richiesta: $Required"
}

function Update-AclPlanActionState {
    $Selected = $AclObjectsGrid.SelectedItem
    $Eligible = $false
    $Reason = "Seleziona un oggetto verificato di cui sei Proprietario."
    if ($script:AclRecoveryRequired) {
        $Reason = if (Test-ImportSessionActive) {
            "Recupero obbligatorio: usare Recupera ACL o Gestisci journal prima di calcolare un nuovo piano."
        } else {
            "Recupero obbligatorio: avviare la sessione e usare Recupera ACL prima di calcolare un nuovo piano."
        }
    } elseif (-not (Test-ImportSessionActive)) {
        $Reason = "Avvia prima la sessione sicura Passbolt."
    } elseif ($script:AclCatalogSessionId -ne $script:ImportSessionId) {
        $Reason = "Leggi prima il catalogo ACL della sessione corrente."
    } elseif ($null -eq $Selected) {
        $Reason = "Seleziona una cartella o una risorsa."
    } else {
        $Raw = $Selected.Raw
        if (-not [bool]$Raw.acl_complete) {
            $Reason = "La ACL corrente e' incompleta: il dry-run resta bloccato."
        } elseif (-not [bool]$Raw.subjects_verified) {
            $Reason = "Uno o piu' soggetti non sono verificabili: il dry-run resta bloccato."
        } elseif ([int]$Raw.current_access_type -ne 15) {
            $Reason = "Il dry-run e' disponibile soltanto al proprietario dell'oggetto."
        } else {
            $Eligible = $true
            $Reason = "Costruisci un confronto prima/dopo read-only; nessuna modifica verra' applicata."
        }
    }
    $AclPlanButton.IsEnabled = $Eligible
    $AclPlanButton.ToolTip = $Reason
}

function Update-AclPermissionDetail {
    if ($script:UpdatingAclSelection) { return }
    $Selected = $AclObjectsGrid.SelectedItem
    if ($null -eq $Selected) {
        $AclPermissionsGrid.ItemsSource = $null
        $AclObjectSummary.Text = "Seleziona un oggetto per visualizzare la relativa ACL."
        if ($null -ne $script:AclPlan) { Reset-AclPlan }
        Update-AclPlanActionState
        return
    }
    $Raw = $Selected.Raw
    if ($null -ne $script:AclPlan -and (
        [string]$script:AclPlan.object.object_type -ne [string]$Raw.object_type -or
        [string]$script:AclPlan.object.object_id -ne [string]$Raw.object_id
    )) {
        Reset-AclPlan "La selezione e' cambiata. Calcolare un nuovo piano read-only per l'oggetto corrente."
    }
    $Rows = New-Object System.Collections.Generic.List[object]
    foreach ($Permission in @($Raw.permissions)) {
        $Rows.Add([pscustomobject]@{
            SubjectType = [string]$Permission.subject_type
            DisplayName = [string]$Permission.display_name
            Detail = [string]$Permission.detail
            PermissionLabel = [string]$Permission.permission_label
            VerificationLabel = if ([bool]$Permission.verified) { "Verificata" } else { "Attenzione" }
            VerificationStatus = [string]$Permission.verification_status
            RecipientCount = [int]$Permission.recipient_count
            CurrentUser = [bool]$Permission.current_user
            SubjectId = [string]$Permission.subject_id
        })
    }
    $AclPermissionsGrid.ItemsSource = $Rows.ToArray()
    $WarningText = @($Raw.warnings) -join " "
    $StatusText = Get-AclInspectionStatusLabel ([string]$Raw.inspection_status)
    $Completeness = if ([bool]$Raw.acl_complete) { "maschera completa" } else { "maschera incompleta" }
    $Verification = if ([bool]$Raw.subjects_verified) { "soggetti verificati" } else { "uno o piu' soggetti richiedono attenzione" }
    $WarningSuffix = if ([string]::IsNullOrWhiteSpace($WarningText)) { "" } else { " $WarningText" }
    $AclObjectSummary.Text = "$([string]$Raw.object_type_label): $([string]$Raw.path)`nID: $([string]$Raw.object_id)`nAccesso corrente: $([string]$Raw.current_access_label) | $([string]$Raw.sharing_label) | ACL $StatusText ($Completeness, $Verification).$WarningSuffix"
    Update-AclPlanActionState
}

function Update-AclObjectFilter {
    $PreviousId = if ($null -ne $AclObjectsGrid.SelectedItem) { [string]$AclObjectsGrid.SelectedItem.ObjectId } else { "" }
    $Type = if ($null -ne $AclTypeFilter.SelectedItem) { [string]$AclTypeFilter.SelectedItem.Tag } else { "all" }
    $Search = ([string]$AclSearchBox.Text).Trim().ToLowerInvariant()
    $Filtered = @($script:AllAclObjectRows | Where-Object {
        $TypeMatches = ($Type -eq "all" -or [string]$_.ObjectType -eq $Type)
        $Haystack = "$([string]$_.Path) $([string]$_.ObjectId) $([string]$_.Name)".ToLowerInvariant()
        $TypeMatches -and (-not $Search -or $Haystack.Contains($Search))
    })
    $script:UpdatingAclSelection = $true
    try {
        $AclObjectsGrid.ItemsSource = $Filtered
        $Selection = if ($PreviousId) { @($Filtered | Where-Object { [string]$_.ObjectId -eq $PreviousId }) | Select-Object -First 1 } else { $null }
        if ($null -eq $Selection -and $Filtered.Count -gt 0) { $Selection = $Filtered[0] }
        $AclObjectsGrid.SelectedItem = $Selection
    } finally {
        $script:UpdatingAclSelection = $false
    }
    Update-AclPermissionDetail
}

function Set-AclCatalogResult($Result) {
    if ($null -eq $Result -or [string]$Result.command -ne "acl-catalog" -or -not [bool]$Result.read_only -or [int]$Result.write_requests -ne 0) {
        throw "Passbolt non ha restituito un catalogo ACL read-only valido."
    }
    Reset-AclPlan "Catalogo aggiornato. Seleziona un oggetto verificato di cui sei Proprietario per calcolare un piano."
    $Rows = New-Object System.Collections.Generic.List[object]
    foreach ($Entry in @($Result.objects)) {
        $Rows.Add([pscustomobject]@{
            ObjectType = [string]$Entry.object_type
            ObjectTypeLabel = [string]$Entry.object_type_label
            ObjectId = [string]$Entry.object_id
            Name = [string]$Entry.name
            Path = [string]$Entry.path
            CurrentAccessLabel = [string]$Entry.current_access_label
            SharingLabel = [string]$Entry.sharing_label
            StatusLabel = Get-AclInspectionStatusLabel ([string]$Entry.inspection_status)
            Raw = $Entry
        })
    }
    $script:AllAclObjectRows = $Rows.ToArray()
    $script:AclCatalogSessionId = $script:ImportSessionId
    Update-AclObjectFilter
    $AclViewerStatus.Text = "Sola lettura: $([int]$Result.folder_count) cartelle, $([int]$Result.resource_count) risorse, $([int]$Result.shared_count) oggetti condivisi. ACL verificate: $([int]$Result.verified_count); con avvisi o incomplete: $([int]$Result.warning_count)."
}

function Update-AclViewerState {
    $Active = Test-ImportSessionActive
    $RefreshAclButton.IsEnabled = $Active
    if (-not $Active) {
        $AclViewerStatus.Text = "Avvia la sessione sicura, quindi leggi i permessi esistenti."
    } elseif ($script:AclCatalogSessionId -ne $script:ImportSessionId) {
        $AclViewerStatus.Text = "Sessione attiva. Seleziona Leggi permessi per caricare il catalogo read-only."
    }
    Update-AclPlanActionState
    Update-AclApplyActionState
}

function Set-AclPlanResult($Result) {
    if ($null -eq $Result -or [string]$Result.command -ne "acl-plan" -or -not [bool]$Result.read_only -or [int]$Result.write_requests -ne 0 -or [int]$Result.remote_writes_planned -ne 0 -or -not [bool]$Result.complete -or -not [bool]$Result.generated_from_fresh_remote_state) {
        throw "Passbolt non ha restituito un piano ACL read-only valido."
    }
    $Selected = $AclObjectsGrid.SelectedItem
    if ($null -eq $Selected -or [string]$Selected.Raw.object_type -ne [string]$Result.object.object_type -or [string]$Selected.Raw.object_id -ne [string]$Result.object.object_id) {
        throw "L'oggetto selezionato non corrisponde al piano ACL restituito."
    }
    $Rows = New-Object System.Collections.Generic.List[object]
    foreach ($Operation in @($Result.operations)) {
        $Rows.Add([pscustomobject]@{
            Sequence = [int]$Operation.sequence
            Action = [string]$Operation.action
            ActionLabel = [string]$Operation.action_label
            DisplayName = "[$([string]$Operation.subject_type)] $([string]$Operation.display_name)"
            Detail = [string]$Operation.detail
            BeforeLabel = [string]$Operation.before_permission_label
            AfterLabel = [string]$Operation.after_permission_label
            ImpactLabel = "$([string]$Operation.direction_label) / $([string]$Operation.risk_label)"
            Sensitive = [bool]$Operation.sensitive
            SubjectId = [string]$Operation.subject_id
        })
    }
    $script:AclPlan = $Result
    $AclPlanGrid.ItemsSource = $Rows.ToArray()
    $Counts = $Result.counts
    $NoChanges = if ([int]$Result.change_count -eq 0) { " Nessuna modifica rilevata." } else { "" }
    $AclPlanSummary.Text = "Piano read-only: $([int]$Result.change_count) modifiche; aggiunte $([int]$Counts.add), aumenti $([int]$Counts.upgrade), riduzioni $([int]$Counts.downgrade), revoche $([int]$Counts.revoke), invariate $([int]$Counts.unchanged). Azioni sensibili: $([int]$Result.sensitive_action_count).$NoChanges`nDigest snapshot: $([string]$Result.object_state_digest)`nDigest piano: $([string]$Result.plan_digest)"
    $Impact = $Result.effective_user_counts
    $OwnerGuard = $Result.last_owner_protection
    if ($null -ne $Impact) {
        $AclPlanSummary.Text += "`nImpatto utenti effettivi: ottengono accesso $([int]$Impact.gain), accesso aumentato $([int]$Impact.upgrade), accesso ridotto $([int]$Impact.downgrade), perdono accesso $([int]$Impact.loss)."
    }
    if ($null -ne $OwnerGuard) {
        $AclPlanSummary.Text += " Protezione proprietario: $([int]$OwnerGuard.owner_count_after) Owner nel risultato; proprietario autenticato conservato."
    }
    $LostUsers = @($Result.effective_user_changes | Where-Object { [string]$_.action -eq "loss" } | ForEach-Object { [string]$_.display_name })
    if ($LostUsers.Count -gt 0) {
        $Preview = @($LostUsers | Select-Object -First 8) -join ", "
        $Suffix = if ($LostUsers.Count -gt 8) { " (+$($LostUsers.Count - 8) altri)" } else { "" }
        $AclPlanSummary.Text += "`nPerderanno accesso: $Preview$Suffix."
    }
    if ([bool]$Result.apply_available) {
        if ([bool]$Result.destructive_actions_planned) {
            $AclPlanSummary.Text += "`nATTENZIONE: piano $([string]$Result.apply_mode) applicabile con $([int]$Result.restrictive_change_count) riduzioni/revoche. Conferma rafforzata richiesta: $([string]$Result.confirmation_required)"
        } else {
            $AclPlanSummary.Text += "`nOperazione additiva applicabile. Conferma richiesta: $([string]$Result.confirmation_required)"
        }
    }
    $AclPlanSummary.ToolTip = "Digest ACL desiderata: $([string]$Result.desired_acl_digest)`nDigest directory verificata: $([string]$Result.directory_state_digest)`nID piano volatile: $([string]$Result.plan_id)"
    $AclConfirmation.Text = ""
    $AclDetailTabs.SelectedIndex = 1
    Update-AclApplyActionState
}

function Start-AclDryRunOperation([object]$Raw, [object]$EditorResult) {
    if ($null -eq $EditorResult) { return }
    Reset-AclPlan "Rilettura dello stato remoto e calcolo del confronto prima/dopo in corso..."
    $AclViewerStatus.Text = "Calcolo autenticato del piano ACL read-only in corso..."
    Add-Activity "Avvio dry-run ACL read-only per $([string]$Raw.object_type) $([string]$Raw.object_id)."
    $Request = [pscustomobject][ordered]@{
        command = "session-acl-plan"
        session_id = $script:ImportSessionId
        object_type = [string]$Raw.object_type
        object_id = [string]$Raw.object_id
        desired_permissions = @($EditorResult.Entries)
    }
    $OperationParameters = @{
        Name = "Dry-run ACL"
        Category = "verify"
        WorkKind = "ImportSessionJson"
        Payload = New-ImportSessionOperationPayload $Request 120000
        OnSuccess = {
            param($Envelope, $Operation)
            if (-not [bool]$Envelope.ok) {
                $FailureMessage = Get-SecureErrorMessage $Envelope
                Reset-AclPlan "Dry-run ACL non riuscito. Nessuna modifica e' stata applicata."
                $AclViewerStatus.Text = "Dry-run ACL non riuscito: $FailureMessage"
                Add-Activity "Dry-run ACL non riuscito: $FailureMessage"
                if ((Test-TerminalImportSessionError $Envelope) -or -not (Test-ImportSessionActive)) { Stop-ImportSession "" $false }
                Update-AclPlanActionState
                [System.Windows.MessageBox]::Show($FailureMessage, "Piano ACL non disponibile", "OK", "Error") | Out-Null
                return
            }
            Set-AclPlanResult $Envelope.result
            $AclViewerStatus.Text = "Piano ACL calcolato su uno snapshot remoto fresco. Richieste di scrittura inviate: 0."
            Add-Activity "Dry-run ACL completato: $([int]$Envelope.result.change_count) modifiche classificate, 0 richieste di scrittura."
            Update-AclPlanActionState
        }
        OnFailure = {
            param($FailureMessage, $Operation)
            Reset-AclPlan "Dry-run ACL non riuscito. Nessuna modifica e' stata applicata."
            $AclViewerStatus.Text = "Dry-run ACL non riuscito: $FailureMessage"
            Add-Activity "Dry-run ACL non riuscito: $FailureMessage"
            Stop-ImportSession "" $false
            Update-AclPlanActionState
            [System.Windows.MessageBox]::Show($FailureMessage, "Piano ACL non disponibile", "OK", "Error") | Out-Null
        }
    }
    [void](Start-UiOperation @OperationParameters)
}

function Invoke-AclDryRun {
    Update-AclPlanActionState
    if (-not $AclPlanButton.IsEnabled) {
        [System.Windows.MessageBox]::Show([string]$AclPlanButton.ToolTip, "Dry-run ACL non disponibile", "OK", "Warning") | Out-Null
        return
    }
    $Raw = $AclObjectsGrid.SelectedItem.Raw
    $InitialPermissions = @($Raw.permissions | Where-Object { -not [bool]$_.current_user } | ForEach-Object {
        [pscustomobject][ordered]@{
            aro = [string]$_.subject_kind
            aro_foreign_key = [string]$_.subject_id
            type = [int]$_.permission_type
        }
    })
    $EditorParameters = @{
        AclPlanMode = $true
        InitialPermissions = $InitialPermissions
        TargetPath = [string]$Raw.path
        CallbackContext = $Raw
        OnCompleted = {
            param($EditorResult, $RawContext)
            Start-AclDryRunOperation $RawContext $EditorResult
        }
    }
    Open-PermissionEditorAsync @EditorParameters
}
function Invoke-ConfirmedAclApply {
    Update-AclApplyActionState
    if (-not $ApplyAclButton.IsEnabled -or $null -eq $script:AclPlan) {
        [System.Windows.MessageBox]::Show([string]$ApplyAclButton.ToolTip, "Applicazione ACL non disponibile", "OK", "Warning") | Out-Null
        return
    }
    $Plan = $script:AclPlan
    if ([bool]$Plan.destructive_actions_planned) {
        $Counts = $Plan.counts
        $Effective = $Plan.effective_user_counts
        $WarningLines = @(
            "ATTENZIONE: questa operazione riduce accessi esistenti.",
            "",
            "Oggetto: $([string]$Plan.object.path)",
            "Riduzioni: $([int]$Counts.downgrade)",
            "Revoche: $([int]$Counts.revoke)",
            "Utenti effettivi con accesso ridotto: $([int]$Effective.downgrade)",
            "Utenti effettivi che perderanno accesso: $([int]$Effective.loss)",
            "",
            "Il proprietario autenticato resterà Owner. Continuare?"
        ) -join [Environment]::NewLine
        $Decision = [System.Windows.MessageBox]::Show($WarningLines, "Conferma modifica ACL restrittiva", "YesNo", "Warning")
        if ($Decision -ne [System.Windows.MessageBoxResult]::Yes) {
            Add-Activity "Applicazione ACL restrittiva annullata prima della scrittura."
            return
        }
    }
    $AclViewerStatus.Text = "Rilettura dello stato remoto, simulazione e applicazione ACL in corso..."
    Add-Activity "Avvio applicazione ACL $([string]$Plan.apply_mode) vincolata al piano $([string]$Plan.plan_digest)."
    $Request = [pscustomobject][ordered]@{
        command = "session-acl-apply"
        session_id = $script:ImportSessionId
        plan_id = [string]$Plan.plan_id
        object_state_digest = [string]$Plan.object_state_digest
        desired_acl_digest = [string]$Plan.desired_acl_digest
        directory_state_digest = [string]$Plan.directory_state_digest
        plan_digest = [string]$Plan.plan_digest
        confirmation = [string]$AclConfirmation.Text
    }
    $OperationParameters = @{
        Name = "Applicazione ACL"
        Category = "write"
        WorkKind = "ImportSessionJson"
        Payload = New-ImportSessionOperationPayload $Request 180000
        OnSuccess = {
            param($Envelope, $Operation)
            if (-not [bool]$Envelope.ok) {
                $FailureMessage = Get-SecureErrorMessage $Envelope
                $BatchId = if ($null -ne $Envelope.error.details) { [string]$Envelope.error.details.acl_batch_id } else { "" }
                $script:AclRecoveryRequired = $true
                $script:AclRecoveryBlockingCount = [Math]::Max(1, [int]$script:AclRecoveryBlockingCount)
                Reset-AclPlan "Applicazione ACL non completata. Non ripetere il dry-run: usare Recupera ACL per verificare lo stato remoto."
                $AclViewerStatus.Text = "Applicazione ACL non completata: $FailureMessage"
                Add-Activity "Applicazione ACL non completata. Journal da verificare: $BatchId. $FailureMessage"
                if ((Test-TerminalImportSessionError $Envelope) -or -not (Test-ImportSessionActive)) { Stop-ImportSession "" $false }
                Update-AclApplyActionState
                Update-AclPlanActionState
                $JournalText = if ($BatchId) { [Environment]::NewLine + [Environment]::NewLine + "Journal ACL: $BatchId" + [Environment]::NewLine + "Usare Recupera ACL prima di qualsiasi nuovo tentativo." } else { "" }
                [System.Windows.MessageBox]::Show("$FailureMessage$JournalText", "Applicazione ACL non completata", "OK", "Error") | Out-Null
                return
            }
            $Result = $Envelope.result
            Add-Activity "ACL applicata: $([int]$Result.permission_change_count) modifiche, $([int]$Result.added_user_count) utenti aggiunti, $([int]$Result.removed_user_count) utenti rimossi. Journal $([string]$Result.acl_batch_id) completato."
            $Summary = @(
                "ACL applicata correttamente.",
                "",
                "Modifiche inviate: $([int]$Result.permission_change_count)",
                "Nuovi destinatari del segreto: $([int]$Result.added_user_count)",
                "Utenti effettivi rimossi: $([int]$Result.removed_user_count)",
                "Modifiche restrittive: $([int]$Result.restrictive_change_count)",
                "Journal: $([string]$Result.acl_batch_id)"
            ) -join [Environment]::NewLine
            [System.Windows.MessageBox]::Show($Summary, "ACL applicata", "OK", "Information") | Out-Null
            Refresh-ExistingAclCatalog
        }
        OnFailure = {
            param($FailureMessage, $Operation)
            $script:AclRecoveryRequired = $true
            $script:AclRecoveryBlockingCount = [Math]::Max(1, [int]$script:AclRecoveryBlockingCount)
            Reset-AclPlan "Applicazione ACL non completata. Non ripetere il dry-run: usare Recupera ACL per verificare lo stato remoto."
            $AclViewerStatus.Text = "Applicazione ACL non completata: $FailureMessage"
            Add-Activity "Applicazione ACL non completata con esito remoto non determinabile: $FailureMessage"
            Stop-ImportSession "" $false
            Update-AclApplyActionState
            Update-AclPlanActionState
            [System.Windows.MessageBox]::Show(
                $FailureMessage + [Environment]::NewLine + [Environment]::NewLine + "L'esito remoto non è considerato non applicato. Usare Recupera ACL prima di qualsiasi nuovo tentativo.",
                "Applicazione ACL non completata",
                "OK",
                "Error"
            ) | Out-Null
        }
    }
    [void](Start-UiOperation @OperationParameters)
}
function Select-AclRecoveryBatch($Batches) {
    $Rows = @($Batches)
    if ($Rows.Count -eq 0) { return $null }
    if ($Rows.Count -eq 1) { return $Rows[0] }
    $Dialog = New-Object System.Windows.Forms.Form
    $Dialog.Text = "Seleziona journal ACL"
    $Dialog.StartPosition = "CenterParent"
    $Dialog.Width = 760
    $Dialog.Height = 390
    $Dialog.MinimizeBox = $false
    $Dialog.MaximizeBox = $false
    $Dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $Label = New-Object System.Windows.Forms.Label
    $Label.Text = "Seleziona il journal da verificare. Data, tipo, ID oggetto e numero modifiche sono dati tecnici locali."
    $Label.AutoSize = $false
    $Label.Left = 12; $Label.Top = 12; $Label.Width = 720; $Label.Height = 38
    $List = New-Object System.Windows.Forms.ListBox
    $List.Left = 12; $List.Top = 54; $List.Width = 720; $List.Height = 235
    foreach ($Batch in $Rows) {
        $When = if ($Batch.recorded_at) { [string]$Batch.recorded_at } else { "data non disponibile" }
        $Display = "$When | $([string]$Batch.object_type) | $([string]$Batch.object_id) | $([int]$Batch.change_count) modifiche | $([string]$Batch.batch_id)"
        [void]$List.Items.Add([pscustomobject]@{ Display = $Display; Raw = $Batch })
    }
    $List.DisplayMember = "Display"
    $List.SelectedIndex = 0
    $Ok = New-Object System.Windows.Forms.Button
    $Ok.Text = "Verifica"; $Ok.Left = 552; $Ok.Top = 305; $Ok.Width = 85
    $Ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $Cancel = New-Object System.Windows.Forms.Button
    $Cancel.Text = "Annulla"; $Cancel.Left = 647; $Cancel.Top = 305; $Cancel.Width = 85
    $Cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $Dialog.Controls.AddRange(@($Label, $List, $Ok, $Cancel))
    $Dialog.AcceptButton = $Ok; $Dialog.CancelButton = $Cancel
    try {
        if ($Dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK -or $null -eq $List.SelectedItem) { return $null }
        return $List.SelectedItem.Raw
    } finally {
        $Dialog.Dispose()
    }
}

function Read-AclRecoveryConfirmation([string]$Message, [string]$Required, [string]$Title = "Conferma recupero ACL") {
    $Dialog = New-Object System.Windows.Forms.Form
    $Dialog.Text = $Title
    $Dialog.StartPosition = "CenterParent"
    $Dialog.Width = 640; $Dialog.Height = 245
    $Dialog.MinimizeBox = $false; $Dialog.MaximizeBox = $false
    $Dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $Label = New-Object System.Windows.Forms.Label
    $Label.Text = "$Message`r`n`r`nDigitare esattamente: $Required"
    $Label.Left = 12; $Label.Top = 12; $Label.Width = 600; $Label.Height = 105
    $Input = New-Object System.Windows.Forms.TextBox
    $Input.Left = 12; $Input.Top = 122; $Input.Width = 600
    $Ok = New-Object System.Windows.Forms.Button
    $Ok.Text = "Continua"; $Ok.Left = 432; $Ok.Top = 158; $Ok.Width = 85
    $Ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $Cancel = New-Object System.Windows.Forms.Button
    $Cancel.Text = "Annulla"; $Cancel.Left = 527; $Cancel.Top = 158; $Cancel.Width = 85
    $Cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $Dialog.Controls.AddRange(@($Label, $Input, $Ok, $Cancel))
    $Dialog.AcceptButton = $Ok; $Dialog.CancelButton = $Cancel
    try {
        if ($Dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
        return [string]$Input.Text
    } finally {
        $Dialog.Dispose()
    }
}

function Get-AclJournalStatusText([string]$Value) {
    switch ($Value) {
        "recovery_required" { return "Recuperabile" }
        "complete" { return "Completo" }
        "truncated" { return "Troncato" }
        "corrupt" { return "Corrotto" }
        default { return "Sconosciuto" }
    }
}

function Get-AclJournalTypeText([string]$Value) {
    if ($Value -eq "folder") { return "Cartella" }
    if ($Value -eq "resource") { return "Risorsa" }
    return [string][char]0x2014
}

function Get-AclJournalModeText([string]$Value) {
    switch ($Value) {
        "additive" { return "Additiva" }
        "mixed" { return "Mista" }
        "restrictive" { return "Restrittiva" }
        default { return [string][char]0x2014 }
    }
}

function Get-AclJournalManagerSelection([object]$Context) {
    if ($Context.Grid.SelectedRows.Count -eq 0) { return $null }
    return $Context.Grid.SelectedRows[0].Tag
}

function Update-AclJournalManagerRows([object]$Context) {
    if ($Context.State.Loading) { return }
    $Context.State.Loading = $true
    try {
        $SelectedBefore = Get-AclJournalManagerSelection $Context
        $SelectedId = if ($null -ne $SelectedBefore) { [string]$SelectedBefore.batch_id } else { "" }
        $StatusValue = [string]$Context.StatusFilter.SelectedItem.Value
        $TypeValue = [string]$Context.TypeFilter.SelectedItem.Value
        $Days = [int]$Context.DateFilter.SelectedItem.Days
        $Threshold = if ($Days -gt 0) { [DateTimeOffset]::UtcNow.AddDays(-$Days) } else { [DateTimeOffset]::MinValue }
        $Needle = $Context.SearchBox.Text.Trim().ToLowerInvariant()
        $Context.Grid.Rows.Clear()
        foreach ($Batch in @($Context.State.Batches)) {
            if ($StatusValue -ne "all" -and [string]$Batch.status -ne $StatusValue) { continue }
            if ($TypeValue -ne "all" -and [string]$Batch.object_type -ne $TypeValue) { continue }
            if ($Days -gt 0) {
                if (-not [string]$Batch.recorded_at) { continue }
                try { if ([DateTimeOffset]::Parse([string]$Batch.recorded_at) -lt $Threshold) { continue } } catch { continue }
            }
            $Haystack = "$([string]$Batch.batch_id) $([string]$Batch.object_id) $([string]$Batch.object_type) $([string]$Batch.status) $([string]$Batch.apply_mode)".ToLowerInvariant()
            if ($Needle -and -not $Haystack.Contains($Needle)) { continue }
            $When = [string][char]0x2014
            if ([string]$Batch.recorded_at) {
                try { $When = ([DateTimeOffset]::Parse([string]$Batch.recorded_at)).ToLocalTime().ToString("dd/MM/yyyy HH:mm") } catch { $When = [string]$Batch.recorded_at }
            }
            $Changes = if ($null -eq $Batch.change_count) { [string][char]0x2014 } else { [string]$Batch.change_count }
            $Index = $Context.Grid.Rows.Add(@(
                $When,
                (Get-AclJournalStatusText ([string]$Batch.status)),
                (Get-AclJournalTypeText ([string]$Batch.object_type)),
                $(if ([string]$Batch.object_id) { [string]$Batch.object_id } else { [string][char]0x2014 }),
                (Get-AclJournalModeText ([string]$Batch.apply_mode)),
                $Changes,
                [string]$Batch.batch_id
            ))
            $Context.Grid.Rows[$Index].Tag = $Batch
            if ($SelectedId -and [string]$Batch.batch_id -eq $SelectedId) {
                $Context.Grid.Rows[$Index].Selected = $true
                $Context.Grid.CurrentCell = $Context.Grid.Rows[$Index].Cells[0]
            }
        }
        $Context.CountLabel.Text = "$($Context.Grid.Rows.Count) journal visualizzati su $(@($Context.State.Batches).Count) attivi"
        if ($Context.Grid.Rows.Count -gt 0 -and $Context.Grid.SelectedRows.Count -eq 0) {
            $Context.Grid.Rows[0].Selected = $true
            $Context.Grid.CurrentCell = $Context.Grid.Rows[0].Cells[0]
        }
        $Context.ArchiveButton.Enabled = $Context.Grid.SelectedRows.Count -gt 0
        if ($Context.Grid.Rows.Count -eq 0) { $Context.Details.Text = "Nessun journal corrisponde ai filtri selezionati." }
    } finally {
        $Context.State.Loading = $false
    }
}

function Start-AclJournalManagerDetails([object]$Context) {
    if ($Context.State.Loading -or (Test-OperationActive)) { return }
    $Selected = Get-AclJournalManagerSelection $Context
    $Context.ArchiveButton.Enabled = $null -ne $Selected
    if ($null -eq $Selected) { $Context.Details.Text = "Selezionare un journal."; return }
    $Request = [pscustomobject]@{ batch_id = [string]$Selected.batch_id }
    $OperationParameters = @{
        Name = "Dettaglio journal ACL"
        Category = "read"
        WorkKind = "SecureJsonProcess"
        Payload = New-SecureJsonOperationPayload $PythonExecutable @($ImportScript, "--acl-reconciliation-describe") $Request 30000
        InteractiveSurface = $Context.Dialog
        Context = [pscustomobject]@{ Manager = $Context; BatchId = [string]$Selected.batch_id; Status = [string]$Selected.status }
        OnSuccess = {
            param($Envelope, $Operation)
            try {
                if (-not [bool]$Envelope.ok) { throw (Get-SecureErrorMessage $Envelope) }
                $Item = $Envelope.result
                if ([string]$Item.batch_id -ne [string]$Operation.Context.BatchId -or [string]$Item.status -ne [string]$Operation.Context.Status) { throw "Lo stato del journal ACL e' cambiato. Aggiornare l'elenco." }
                if ([string]$Item.status -eq "corrupt") {
                    $Operation.Context.Manager.Details.Text = "ID journal: $([string]$Item.batch_id)`r`nStato: Corrotto`r`n`r`nIl contenuto non e' attendibile e non viene interpretato. Il recupero automatico e' bloccato; e' disponibile soltanto l'archiviazione non distruttiva."
                } else {
                    $Operation.Context.Manager.Details.Text = @(
                        "ID journal: $([string]$Item.batch_id)",
                        "Stato: $(Get-AclJournalStatusText ([string]$Item.status))",
                        "Oggetto: $(Get-AclJournalTypeText ([string]$Item.object_type)) | $([string]$Item.object_id)",
                        "Modalita': $(Get-AclJournalModeText ([string]$Item.apply_mode))",
                        "Modifiche: $([int]$Item.change_count) (aggiunte $([int]$Item.add_count), aumenti $([int]$Item.upgrade_count), riduzioni $([int]$Item.downgrade_count), revoche $([int]$Item.revoke_count))",
                        "Eventi: $([int]$Item.event_count) | applicazioni $([int]$Item.applied_operation_count) | errori $([int]$Item.failed_operation_count) | verifiche recupero $([int]$Item.recovery_verification_count)",
                        "Coda troncata: $(if ([bool]$Item.truncated_tail) { 'si' } else { 'no' })"
                    ) -join "`r`n"
                }
            } catch { $Operation.Context.Manager.Details.Text = "Dettaglio non disponibile: $($_.Exception.Message)" }
        }
        OnFailure = {
            param($FailureMessage, $Operation)
            $Operation.Context.Manager.Details.Text = "Dettaglio non disponibile: $FailureMessage"
        }
    }
    [void](Start-UiOperation @OperationParameters)
}

function Start-AclJournalManagerRefresh([object]$Context) {
    if (Test-OperationActive) { return }
    $Context.Details.Text = "Lettura dei metadati locali in corso..."
    $OperationParameters = @{
        Name = "Elenco journal ACL"
        Category = "read"
        WorkKind = "PythonJson"
        Payload = New-PythonJsonOperationPayload $ImportScript @("--acl-reconciliation-list")
        InteractiveSurface = $Context.Dialog
        Context = $Context
        OnSuccess = {
            param($Envelope, $Operation)
            if (-not [bool]$Envelope.ok) {
                $FailureMessage = Get-SecureErrorMessage $Envelope
                $Operation.Context.State.Batches = @()
                Update-AclJournalManagerRows $Operation.Context
                $Operation.Context.CountLabel.Text = "Elenco non disponibile"
                $Operation.Context.Details.Text = "Elenco dei journal ACL non disponibile: $FailureMessage"
                Add-Activity "Elenco journal ACL non disponibile: $FailureMessage"
                return
            }
            $Operation.Context.State.Batches = @($Envelope.result.batches)
            Update-AclJournalManagerRows $Operation.Context
            Add-Activity "Journal ACL aggiornati: $(@($Operation.Context.State.Batches).Count) lotti attivi; nessun percorso, destinatario o segreto esposto."
            Start-AclJournalManagerDetails $Operation.Context
        }
        OnFailure = {
            param($FailureMessage, $Operation)
            $Operation.Context.State.Batches = @()
            Update-AclJournalManagerRows $Operation.Context
            $Operation.Context.CountLabel.Text = "Elenco non disponibile"
            $Operation.Context.Details.Text = "Elenco dei journal ACL non disponibile: $FailureMessage"
            Add-Activity "Elenco journal ACL non disponibile: $FailureMessage"
        }
    }
    [void](Start-UiOperation @OperationParameters)
}

function Start-AclJournalManagerArchive([object]$Context, [object]$Selected, [string]$Confirmation) {
    $Request = [pscustomobject]@{ batch_id = [string]$Selected.batch_id; expected_status = [string]$Selected.status; confirmation = $Confirmation }
    $OperationParameters = @{
        Name = "Archiviazione journal ACL"
        Category = "write"
        WorkKind = "SecureJsonProcess"
        Payload = New-SecureJsonOperationPayload $PythonExecutable @($ImportScript, "--acl-reconciliation-archive") $Request 30000
        InteractiveSurface = $Context.Dialog
        Context = [pscustomobject]@{ Manager = $Context; BatchId = [string]$Selected.batch_id; Status = [string]$Selected.status }
        OnSuccess = {
            param($Envelope, $Operation)
            if (-not [bool]$Envelope.ok -or [bool]$Envelope.result.deleted) {
                $FailureMessage = if (-not [bool]$Envelope.ok) { Get-SecureErrorMessage $Envelope } else { "Il backend ha restituito un esito di cancellazione non consentito." }
                Add-Activity "Archiviazione journal ACL non riuscita: $FailureMessage"
                [System.Windows.Forms.MessageBox]::Show($FailureMessage, "Archiviazione non riuscita", "OK", "Error") | Out-Null
                return
            }
            Add-Activity "Journal ACL $([string]$Operation.Context.BatchId) archiviato dallo stato $([string]$Operation.Context.Status); nessuna evidenza eliminata."
            [System.Windows.Forms.MessageBox]::Show("Journal ACL archiviato correttamente. L'evidenza e' stata spostata, non cancellata.", "Archiviazione completata", "OK", "Information") | Out-Null
            Start-AclJournalManagerRefresh $Operation.Context.Manager
        }
        OnFailure = {
            param($FailureMessage, $Operation)
            Add-Activity "Archiviazione journal ACL non riuscita: $FailureMessage"
            [System.Windows.Forms.MessageBox]::Show($FailureMessage, "Archiviazione non riuscita", "OK", "Error") | Out-Null
        }
    }
    [void](Start-UiOperation @OperationParameters)
}

function Show-AclJournalManager([switch]$BuildOnly) {
    $Dialog = New-Object System.Windows.Forms.Form
    $Dialog.Text = "Gestione journal ACL"
    $Dialog.StartPosition = "CenterParent"
    $Dialog.Width = 1080
    $Dialog.Height = 690
    $Dialog.MinimumSize = New-Object System.Drawing.Size(940, 610)
    $Dialog.MinimizeBox = $false

    $Intro = New-Object System.Windows.Forms.Label
    $Intro.Text = "Journal ACL locali attivi. I dettagli escludono percorsi, identita', fingerprint, destinatari e segreti. Archiviare sposta l'evidenza sotto Archive\<stato> senza cancellarla."
    $Intro.Left = 12; $Intro.Top = 12; $Intro.Width = 1038; $Intro.Height = 38
    $Intro.Anchor = "Top,Left,Right"

    $StatusLabel = New-Object System.Windows.Forms.Label
    $StatusLabel.Text = "Stato"
    $StatusLabel.Left = 12; $StatusLabel.Top = 58; $StatusLabel.Width = 45
    $StatusFilter = New-Object System.Windows.Forms.ComboBox
    $StatusFilter.Left = 58; $StatusFilter.Top = 54; $StatusFilter.Width = 155
    $StatusFilter.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $StatusFilter.DisplayMember = "Label"
    @(
        [pscustomobject]@{ Label = "Tutti gli stati"; Value = "all" },
        [pscustomobject]@{ Label = "Recuperabile"; Value = "recovery_required" },
        [pscustomobject]@{ Label = "Completo"; Value = "complete" },
        [pscustomobject]@{ Label = "Troncato"; Value = "truncated" },
        [pscustomobject]@{ Label = "Corrotto"; Value = "corrupt" }
    ) | ForEach-Object { [void]$StatusFilter.Items.Add($_) }
    $StatusFilter.SelectedIndex = 0

    $TypeLabel = New-Object System.Windows.Forms.Label
    $TypeLabel.Text = "Tipo"
    $TypeLabel.Left = 225; $TypeLabel.Top = 58; $TypeLabel.Width = 35
    $TypeFilter = New-Object System.Windows.Forms.ComboBox
    $TypeFilter.Left = 262; $TypeFilter.Top = 54; $TypeFilter.Width = 135
    $TypeFilter.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $TypeFilter.DisplayMember = "Label"
    @(
        [pscustomobject]@{ Label = "Tutti gli oggetti"; Value = "all" },
        [pscustomobject]@{ Label = "Cartelle"; Value = "folder" },
        [pscustomobject]@{ Label = "Risorse"; Value = "resource" }
    ) | ForEach-Object { [void]$TypeFilter.Items.Add($_) }
    $TypeFilter.SelectedIndex = 0

    $DateLabel = New-Object System.Windows.Forms.Label
    $DateLabel.Text = "Data"
    $DateLabel.Left = 409; $DateLabel.Top = 58; $DateLabel.Width = 35
    $DateFilter = New-Object System.Windows.Forms.ComboBox
    $DateFilter.Left = 446; $DateFilter.Top = 54; $DateFilter.Width = 145
    $DateFilter.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $DateFilter.DisplayMember = "Label"
    @(
        [pscustomobject]@{ Label = "Qualsiasi data"; Days = 0 },
        [pscustomobject]@{ Label = "Ultime 24 ore"; Days = 1 },
        [pscustomobject]@{ Label = "Ultimi 7 giorni"; Days = 7 },
        [pscustomobject]@{ Label = "Ultimi 30 giorni"; Days = 30 }
    ) | ForEach-Object { [void]$DateFilter.Items.Add($_) }
    $DateFilter.SelectedIndex = 0

    $SearchLabel = New-Object System.Windows.Forms.Label
    $SearchLabel.Text = "Cerca"
    $SearchLabel.Left = 603; $SearchLabel.Top = 58; $SearchLabel.Width = 45
    $SearchBox = New-Object System.Windows.Forms.TextBox
    $SearchBox.Left = 650; $SearchBox.Top = 54; $SearchBox.Width = 288
    $SearchBox.Anchor = "Top,Left,Right"
    $SearchBox.MaxLength = 200

    $RefreshButton = New-Object System.Windows.Forms.Button
    $RefreshButton.Text = "Aggiorna"
    $RefreshButton.Left = 950; $RefreshButton.Top = 52; $RefreshButton.Width = 100
    $RefreshButton.Anchor = "Top,Right"

    $Grid = New-Object System.Windows.Forms.DataGridView
    $Grid.Left = 12; $Grid.Top = 88; $Grid.Width = 1038; $Grid.Height = 300
    $Grid.Anchor = "Top,Bottom,Left,Right"
    $Grid.ReadOnly = $true
    $Grid.AllowUserToAddRows = $false
    $Grid.AllowUserToDeleteRows = $false
    $Grid.AllowUserToResizeRows = $false
    $Grid.MultiSelect = $false
    $Grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $Grid.AutoGenerateColumns = $false
    $Grid.RowHeadersVisible = $false
    foreach ($Column in @(
        [pscustomobject]@{ Name = "RecordedAt"; Header = "Data"; Width = 135; Fill = $false },
        [pscustomobject]@{ Name = "Status"; Header = "Stato"; Width = 105; Fill = $false },
        [pscustomobject]@{ Name = "ObjectType"; Header = "Tipo"; Width = 80; Fill = $false },
        [pscustomobject]@{ Name = "ObjectId"; Header = "ID oggetto"; Width = 220; Fill = $true },
        [pscustomobject]@{ Name = "Mode"; Header = "Modalita'"; Width = 95; Fill = $false },
        [pscustomobject]@{ Name = "Changes"; Header = "Modifiche"; Width = 75; Fill = $false },
        [pscustomobject]@{ Name = "BatchId"; Header = "ID journal"; Width = 245; Fill = $false }
    )) {
        $GridColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $GridColumn.Name = $Column.Name
        $GridColumn.HeaderText = $Column.Header
        $GridColumn.Width = $Column.Width
        if ($Column.Fill) { $GridColumn.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill }
        [void]$Grid.Columns.Add($GridColumn)
    }

    $DetailsLabel = New-Object System.Windows.Forms.Label
    $DetailsLabel.Text = "Dettaglio tecnico sicuro"
    $DetailsLabel.Left = 12; $DetailsLabel.Top = 400; $DetailsLabel.Width = 220
    $DetailsLabel.Anchor = "Bottom,Left"
    $Details = New-Object System.Windows.Forms.TextBox
    $Details.Left = 12; $Details.Top = 422; $Details.Width = 1038; $Details.Height = 164
    $Details.Anchor = "Bottom,Left,Right"
    $Details.Multiline = $true
    $Details.ReadOnly = $true
    $Details.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $Details.BackColor = [System.Drawing.Color]::White
    $Details.Text = "Selezionare un journal."

    $CountLabel = New-Object System.Windows.Forms.Label
    $CountLabel.Text = "0 journal"
    $CountLabel.Left = 12; $CountLabel.Top = 606; $CountLabel.Width = 600; $CountLabel.Height = 30
    $CountLabel.Anchor = "Bottom,Left,Right"

    $ArchiveButton = New-Object System.Windows.Forms.Button
    $ArchiveButton.Text = "Archivia..."
    $ArchiveButton.Left = 845; $ArchiveButton.Top = 600; $ArchiveButton.Width = 100
    $ArchiveButton.Anchor = "Bottom,Right"
    $ArchiveButton.Enabled = $false
    $CloseButton = New-Object System.Windows.Forms.Button
    $CloseButton.Text = "Chiudi"
    $CloseButton.Left = 950; $CloseButton.Top = 600; $CloseButton.Width = 100
    $CloseButton.Anchor = "Bottom,Right"
    $CloseButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $Dialog.Controls.AddRange(@(
        $Intro, $StatusLabel, $StatusFilter, $TypeLabel, $TypeFilter,
        $DateLabel, $DateFilter, $SearchLabel, $SearchBox, $RefreshButton,
        $Grid, $DetailsLabel, $Details, $CountLabel, $ArchiveButton, $CloseButton
    ))
    $Dialog.CancelButton = $CloseButton

    $State = [pscustomobject]@{ Batches = @(); Loading = $false }
    $Context = [pscustomobject]@{
        Dialog = $Dialog
        State = $State
        StatusFilter = $StatusFilter
        TypeFilter = $TypeFilter
        DateFilter = $DateFilter
        SearchBox = $SearchBox
        Grid = $Grid
        Details = $Details
        CountLabel = $CountLabel
        ArchiveButton = $ArchiveButton
    }

    $StatusFilter.Add_SelectedIndexChanged({
        Update-AclJournalManagerRows $Context
        Start-AclJournalManagerDetails $Context
    })
    $TypeFilter.Add_SelectedIndexChanged({
        Update-AclJournalManagerRows $Context
        Start-AclJournalManagerDetails $Context
    })
    $DateFilter.Add_SelectedIndexChanged({
        Update-AclJournalManagerRows $Context
        Start-AclJournalManagerDetails $Context
    })
    $SearchBox.Add_TextChanged({
        Update-AclJournalManagerRows $Context
        Start-AclJournalManagerDetails $Context
    })
    $Grid.Add_SelectionChanged({ Start-AclJournalManagerDetails $Context })
    $RefreshButton.Add_Click({ Start-AclJournalManagerRefresh $Context })
    $ArchiveButton.Add_Click({
        $Selected = Get-AclJournalManagerSelection $Context
        if ($null -eq $Selected) { return }
        $BatchId = [string]$Selected.batch_id
        $Status = [string]$Selected.status
        $Warning = "Il journal ACL $BatchId verra' spostato nell'archivio locale dello stato '$(Get-AclJournalStatusText $Status)'." + [Environment]::NewLine + [Environment]::NewLine + "Nessuna evidenza verra' cancellata. Il lotto non comparira' piu nell'elenco attivo. Continuare?"
        if ([System.Windows.Forms.MessageBox]::Show($Warning, "Archivia journal ACL", "YesNo", "Warning") -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $Required = "ARCHIVIA ACL $BatchId"
        $Confirmation = Read-AclRecoveryConfirmation "L'operazione e' locale e non modifica Passbolt. Confermare lo spostamento non distruttivo del journal nello stato corrente." $Required "Conferma archiviazione ACL"
        if ($null -ne $Confirmation) { Start-AclJournalManagerArchive $Context $Selected $Confirmation }
    })
    if ($BuildOnly) {
        $State.Batches = @([pscustomobject]@{
            batch_id = "11111111-1111-4111-8111-111111111111"
            recorded_at = "2026-08-11T12:00:00.000Z"
            status = "recovery_required"
            object_type = "folder"
            object_id = "acl-journal-ui-probe"
            change_count = 1
            add_count = 1
            upgrade_count = 0
            downgrade_count = 0
            revoke_count = 0
            apply_mode = "additive"
        })
        Update-AclJournalManagerRows $Context
        return [pscustomobject]@{
            Window = $Dialog
            StatusFilter = $StatusFilter
            TypeFilter = $TypeFilter
            DateFilter = $DateFilter
            SearchBox = $SearchBox
            Grid = $Grid
            Details = $Details
            ArchiveButton = $ArchiveButton
        }
    }
    try {
        $Dialog.Add_Shown({ Start-AclJournalManagerRefresh $Context })
        [void]$Dialog.ShowDialog()
    } finally {
        $Dialog.Dispose()
    }
    Refresh-AclRecoveryGuard
}

function Set-AclRecoveryGuardFromBatches([object[]]$Batches, [string]$FailureMessage = "") {
    if (-not [string]::IsNullOrWhiteSpace($FailureMessage)) {
        $script:AclRecoveryRequired = $true
        $script:AclRecoveryBlockingCount = -1
        $AclViewerStatus.Text = "Verifica journal ACL non disponibile: $FailureMessage. Nuovi piani bloccati per sicurezza."
        Update-AclPlanActionState
        Update-AclApplyActionState
        return
    }
    $Blocking = @($Batches | Where-Object { [string]$_.status -ne "complete" })
    $script:AclRecoveryBlockingCount = $Blocking.Count
    $script:AclRecoveryRequired = $Blocking.Count -gt 0
    if ($script:AclRecoveryRequired) {
        $AclViewerStatus.Text = "Recupero ACL obbligatorio: $($Blocking.Count) journal locali richiedono verifica o gestione prima di un nuovo piano."
    }
    Update-AclPlanActionState
    Update-AclApplyActionState
}

function Refresh-AclRecoveryGuard {
    $OperationParameters = @{
        Name = "Verifica journal ACL locali"
        Category = "read"
        WorkKind = "PythonJson"
        Payload = New-PythonJsonOperationPayload $ImportScript @("--acl-reconciliation-list")
        OnSuccess = {
            param($Envelope, $Operation)
            if (-not [bool]$Envelope.ok) {
                Set-AclRecoveryGuardFromBatches @() (Get-SecureErrorMessage $Envelope)
                return
            }
            Set-AclRecoveryGuardFromBatches @($Envelope.result.batches)
        }
        OnFailure = {
            param($FailureMessage, $Operation)
            Set-AclRecoveryGuardFromBatches @() $FailureMessage
        }
    }
    [void](Start-UiOperation @OperationParameters)
}

function Complete-AclRecoveryFailure([string]$BatchId, [string]$FailureMessage, [bool]$RemoteOutcomeUncertain = $false) {
    $Suffix = if ($RemoteOutcomeUncertain) { " L'esito remoto non viene classificato come non applicato; ripetere la verifica del journal." } else { "" }
    $AclViewerStatus.Text = "Recupero ACL non riuscito: $FailureMessage$Suffix"
    Add-Activity "Recupero ACL $BatchId non riuscito: $FailureMessage$Suffix"
    Update-AclApplyActionState
    [System.Windows.MessageBox]::Show("$FailureMessage$Suffix", "Recupero ACL non completato", "OK", "Error") | Out-Null
}

function Start-AclRecoveryCancel([string]$BatchId, [string]$StatusText) {
    $Request = [pscustomobject][ordered]@{
        command = "session-acl-recovery-cancel"
        session_id = $script:ImportSessionId
        acl_batch_id = $BatchId
    }
    $OperationParameters = @{
        Name = "Chiusura verifica recupero ACL"
        Category = "recover"
        WorkKind = "ImportSessionJson"
        Payload = New-ImportSessionOperationPayload $Request 30000
        Context = [pscustomobject]@{ BatchId = $BatchId; StatusText = $StatusText }
        OnSuccess = {
            param($Envelope, $Operation)
            if (-not [bool]$Envelope.ok) {
                Complete-AclRecoveryFailure ([string]$Operation.Context.BatchId) (Get-SecureErrorMessage $Envelope)
                return
            }
            $AclViewerStatus.Text = [string]$Operation.Context.StatusText
            Update-AclApplyActionState
        }
        OnFailure = {
            param($FailureMessage, $Operation)
            Complete-AclRecoveryFailure ([string]$Operation.Context.BatchId) $FailureMessage
        }
    }
    [void](Start-UiOperation @OperationParameters)
}

function Start-AclRecoveryApply([string]$BatchId, [object]$Readiness, [string]$Confirmation) {
    $Request = [pscustomobject][ordered]@{
        command = "session-acl-recovery-apply"
        session_id = $script:ImportSessionId
        acl_batch_id = $BatchId
        recovery_id = [string]$Readiness.recovery_id
        recovery_plan_digest = [string]$Readiness.recovery_plan_digest
        confirmation = $Confirmation
    }
    $OperationParameters = @{
        Name = "Applicazione recupero ACL"
        Category = "recover"
        WorkKind = "ImportSessionJson"
        Payload = New-ImportSessionOperationPayload $Request 180000
        Context = [pscustomobject]@{ BatchId = $BatchId }
        OnSuccess = {
            param($Envelope, $Operation)
            if (-not [bool]$Envelope.ok) {
                Complete-AclRecoveryFailure ([string]$Operation.Context.BatchId) (Get-SecureErrorMessage $Envelope)
                return
            }
            $Result = $Envelope.result
            $WriteText = if ([bool]$Result.remote_write_performed) {
                "La modifica ACL è stata applicata. Utenti effettivi rimossi: $([int]$Result.removed_user_count)."
            } else {
                "La modifica risultava già applicata; non è stata inviata alcuna scrittura."
            }
            Add-Activity "Journal ACL $([string]$Operation.Context.BatchId) riconciliato: $([string]$Result.resolution)."
            if ($script:AclRecoveryBlockingCount -gt 0) { $script:AclRecoveryBlockingCount-- }
            $script:AclRecoveryRequired = $script:AclRecoveryBlockingCount -ne 0
            Update-AclViewerState
            [System.Windows.MessageBox]::Show($WriteText + [Environment]::NewLine + [Environment]::NewLine + "Journal chiuso: $([string]$Operation.Context.BatchId)", "Recupero ACL completato", "OK", "Information") | Out-Null
            Refresh-ExistingAclCatalog
        }
        OnFailure = {
            param($FailureMessage, $Operation)
            Complete-AclRecoveryFailure ([string]$Operation.Context.BatchId) $FailureMessage $true
        }
    }
    [void](Start-UiOperation @OperationParameters)
}

function Start-AclRecoveryReadiness([string]$BatchId) {
    $AclViewerStatus.Text = "Verifica autenticata del journal ACL $BatchId in corso..."
    Add-Activity "Avvio verifica idempotente del journal ACL $BatchId."
    $Request = [pscustomobject][ordered]@{
        command = "session-acl-recovery-readiness"
        session_id = $script:ImportSessionId
        acl_batch_id = $BatchId
    }
    $OperationParameters = @{
        Name = "Verifica recupero ACL"
        Category = "recover"
        WorkKind = "ImportSessionJson"
        Payload = New-ImportSessionOperationPayload $Request 180000
        Context = [pscustomobject]@{ BatchId = $BatchId }
        OnSuccess = {
            param($Envelope, $Operation)
            $CurrentBatchId = [string]$Operation.Context.BatchId
            if (-not [bool]$Envelope.ok) {
                Complete-AclRecoveryFailure $CurrentBatchId (Get-SecureErrorMessage $Envelope)
                return
            }
            $Readiness = $Envelope.result
            $ResolutionText = if ([string]$Readiness.resolution -eq "remote_success") {
                "Passbolt contiene già la ACL attesa. Non verrà inviata alcuna scrittura; il journal sarà soltanto chiuso."
            } elseif ([bool]$Readiness.destructive_actions_planned) {
                "Passbolt contiene ancora esattamente lo snapshot originale. Il recupero ripeterà $([int]$Readiness.restrictive_change_count) riduzioni/revoche già registrate e richiede una conferma rafforzata."
            } else {
                "Passbolt contiene ancora esattamente lo snapshot originale. Verranno ripetute soltanto le modifiche ACL verificate."
            }
            $Confirmation = Read-AclRecoveryConfirmation $ResolutionText ([string]$Readiness.confirmation_required)
            if ($null -eq $Confirmation) {
                Start-AclRecoveryCancel $CurrentBatchId "Recupero ACL annullato dopo la verifica; nessuna scrittura applicata."
                return
            }
            if ([bool]$Readiness.destructive_actions_planned) {
                $Warning = @(
                    "Il recupero invierà nuovamente una modifica ACL restrittiva già registrata nel journal.",
                    "",
                    "Riduzioni/revoche: $([int]$Readiness.restrictive_change_count)",
                    "Il bridge verificherà ancora snapshot, piano, directory e proprietario prima della scrittura.",
                    "",
                    "Continuare?"
                ) -join [Environment]::NewLine
                $Decision = [System.Windows.MessageBox]::Show($Warning, "Conferma recupero ACL restrittivo", "YesNo", "Warning")
                if ($Decision -ne [System.Windows.MessageBoxResult]::Yes) {
                    Start-AclRecoveryCancel $CurrentBatchId "Recupero ACL restrittivo annullato; nessuna scrittura applicata."
                    return
                }
            }
            Start-AclRecoveryApply $CurrentBatchId $Readiness $Confirmation
        }
        OnFailure = {
            param($FailureMessage, $Operation)
            Complete-AclRecoveryFailure ([string]$Operation.Context.BatchId) $FailureMessage
        }
    }
    [void](Start-UiOperation @OperationParameters)
}

function Invoke-AclRecovery {
    if (-not (Test-ImportSessionActive)) {
        [System.Windows.MessageBox]::Show("Avviare prima la sessione sicura Passbolt.", "Sessione non attiva", "OK", "Warning") | Out-Null
        return
    }
    $OperationParameters = @{
        Name = "Elenco journal ACL recuperabili"
        Category = "recover"
        WorkKind = "PythonJson"
        Payload = New-PythonJsonOperationPayload $ImportScript @("--acl-reconciliation-list")
        OnSuccess = {
            param($ListEnvelope, $Operation)
            if (-not [bool]$ListEnvelope.ok) {
                $FailureMessage = Get-SecureErrorMessage $ListEnvelope
                Set-AclRecoveryGuardFromBatches @() $FailureMessage
                Add-Activity "Elenco journal ACL non disponibile: $FailureMessage"
                [System.Windows.MessageBox]::Show($FailureMessage, "Journal ACL non disponibili", "OK", "Error") | Out-Null
                return
            }
            $Batches = @($ListEnvelope.result.batches)
            Set-AclRecoveryGuardFromBatches $Batches
            $Pending = @($Batches | Where-Object { [string]$_.status -eq "recovery_required" })
            if ($Pending.Count -eq 0) {
                [System.Windows.MessageBox]::Show("Non risultano journal ACL recuperabili. I journal completi, troncati o corrotti non vengono applicati automaticamente.", "Nessun recupero ACL", "OK", "Information") | Out-Null
                return
            }
            $Selected = Select-AclRecoveryBatch $Pending
            if ($null -ne $Selected) { Start-AclRecoveryReadiness ([string]$Selected.batch_id) }
        }
        OnFailure = {
            param($FailureMessage, $Operation)
            Set-AclRecoveryGuardFromBatches @() $FailureMessage
            Add-Activity "Elenco journal ACL non disponibile: $FailureMessage"
            [System.Windows.MessageBox]::Show($FailureMessage, "Journal ACL non disponibili", "OK", "Error") | Out-Null
        }
    }
    [void](Start-UiOperation @OperationParameters)
}
function Refresh-ExistingAclCatalog {
    if (-not (Test-ImportSessionActive)) {
        [System.Windows.MessageBox]::Show("Avviare prima la sessione sicura Passbolt.", "Sessione non attiva", "OK", "Warning") | Out-Null
        return
    }
    Reset-AclPlan "Aggiornamento del catalogo ACL in corso..."
    $AclViewerStatus.Text = "Lettura autenticata di cartelle, risorse e permessi in corso..."
    Add-Activity "Avvio lettura read-only delle ACL degli oggetti Passbolt esistenti."
    $Request = [pscustomobject][ordered]@{
        command = "session-acl-catalog"
        session_id = $script:ImportSessionId
    }
    $OperationParameters = @{
        Name = "Lettura catalogo ACL"
        Category = "verify"
        WorkKind = "ImportSessionJson"
        Payload = New-ImportSessionOperationPayload $Request 120000
        OnSuccess = {
            param($Envelope, $Operation)
            if (-not [bool]$Envelope.ok) {
                $FailureMessage = Get-SecureErrorMessage $Envelope
                $script:AclCatalogSessionId = ""
                $script:AllAclObjectRows = @()
                $AclObjectsGrid.ItemsSource = $null
                $AclPermissionsGrid.ItemsSource = $null
                $AclObjectSummary.Text = "Seleziona un oggetto per visualizzare la relativa ACL."
                Reset-AclPlan "Catalogo ACL non disponibile. Nessun piano e' stato conservato."
                $AclViewerStatus.Text = "Lettura ACL non riuscita: $FailureMessage"
                Add-Activity "Lettura ACL non riuscita: $FailureMessage"
                if ((Test-TerminalImportSessionError $Envelope) -or -not (Test-ImportSessionActive)) { Stop-ImportSession "" $false }
                Update-AclViewerState
                [System.Windows.MessageBox]::Show($FailureMessage, "Permessi non disponibili", "OK", "Error") | Out-Null
                return
            }
            Set-AclCatalogResult $Envelope.result
            Add-Activity "Catalogo ACL read-only caricato: $(@($script:AllAclObjectRows).Count) oggetti; nessuna richiesta di scrittura inviata."
            Update-AclViewerState
        }
        OnFailure = {
            param($FailureMessage, $Operation)
            $script:AclCatalogSessionId = ""
            $script:AllAclObjectRows = @()
            $AclObjectsGrid.ItemsSource = $null
            $AclPermissionsGrid.ItemsSource = $null
            $AclObjectSummary.Text = "Seleziona un oggetto per visualizzare la relativa ACL."
            Reset-AclPlan "Catalogo ACL non disponibile. Nessun piano e' stato conservato."
            $AclViewerStatus.Text = "Lettura ACL non riuscita: $FailureMessage"
            Add-Activity "Lettura ACL non riuscita: $FailureMessage"
            Stop-ImportSession "" $false
            Update-AclViewerState
            [System.Windows.MessageBox]::Show($FailureMessage, "Permessi non disponibili", "OK", "Error") | Out-Null
        }
    }
    [void](Start-UiOperation @OperationParameters)
}
function Get-RequiredImportClients {
    $ClientsByKey = @{}
    foreach ($Candidate in @($script:ImportCandidates)) {
        $Client = [string]$Candidate.client
        $Key = $Client.Trim().ToLowerInvariant()
        if ($Key -and -not $ClientsByKey.ContainsKey($Key)) {
            $ClientsByKey[$Key] = $Client
        }
    }
    return @($ClientsByKey.Values | Sort-Object)
}

function Get-ClientDestinationMappingPayload {
    $Entries = New-Object System.Collections.Generic.List[object]
    foreach ($Client in @(Get-RequiredImportClients)) {
        if (-not $script:ClientDestinationMap.ContainsKey($Client)) { continue }
        $Value = [string]$script:ClientDestinationMap[$Client]
        if (-not $Value -or $Value -eq "__unassigned__") { continue }
        $FolderId = if ($Value -eq "__root__") { $null } else { $Value }
        $Entries.Add([pscustomobject][ordered]@{
            client = $Client
            folder_id = $FolderId
        })
    }
    return $Entries.ToArray()
}

function Update-ClientMappingButtonState {
    $Clients = @(Get-RequiredImportClients)
    $Configured = 0
    $AvailableIds = @{}
    foreach ($Folder in @($script:AvailableDestinationFolders)) {
        $AvailableIds[[string]$Folder.id] = $true
    }
    foreach ($Client in $Clients) {
        if (-not $script:ClientDestinationMap.ContainsKey($Client)) { continue }
        $Value = [string]$script:ClientDestinationMap[$Client]
        if ($Value -eq "__root__" -or ($Value -and $AvailableIds.ContainsKey($Value))) {
            $Configured++
        }
    }
    $Mode = if ($null -ne $DestinationMode.SelectedItem) { [string]$DestinationMode.SelectedItem.Tag } else { "" }
    $IsMapping = ($Mode -eq "client_mapping")
    $ConfigureClientMappingsButton.Visibility = if ($IsMapping) { "Visible" } else { "Collapsed" }
    $ConfigureClientMappingsButton.IsEnabled = ($IsMapping -and $script:DestinationFolderCatalogLoaded -and $Clients.Count -gt 0)
    if (-not $script:DestinationFolderCatalogLoaded) {
        $ConfigureClientMappingsButton.Content = "Prima carica le cartelle"
    } else {
        $ConfigureClientMappingsButton.Content = "Mappa clienti ($Configured/$($Clients.Count))"
    }
}

function Update-DestinationControlState {
    $Mode = [string]$DestinationMode.SelectedItem.Tag
    $DestinationFolder.IsEnabled = ($Mode -in @("client_folders", "direct_folder"))
    $DestinationFolder.Visibility = if ($Mode -eq "client_mapping") { "Collapsed" } else { "Visible" }
    Update-ClientMappingButtonState
}

function Get-DestinationFolderDisplayText($Folder) {
    if ($null -eq $Folder) { return "" }
    $Label = [string]$Folder.path
    if ([bool]$Folder.shared) {
        $Label += " [Condivisa: $([int]$Folder.share_recipient_count) destinatari]"
    }
    return $Label
}

function Update-DestinationFolderOptions($Folders, [string]$SelectedId = "", [bool]$CatalogLoaded = $true) {
    $script:AvailableDestinationFolders = @($Folders)
    $script:DestinationFolderCatalogLoaded = $CatalogLoaded
    $script:PopulatingDestinationFolders = $true
    try {
        $DestinationFolder.Items.Clear()
        $RootItem = New-Object System.Windows.Controls.ComboBoxItem
        $RootItem.Content = "Radice personale Passbolt"
        $RootItem.Tag = ""
        [void]$DestinationFolder.Items.Add($RootItem)
        $SelectedIndex = 0
        foreach ($Folder in @($Folders)) {
            $Item = New-Object System.Windows.Controls.ComboBoxItem
            $Item.Content = Get-DestinationFolderDisplayText $Folder
            $Item.Tag = [string]$Folder.id
            $Item.ToolTip = if ([bool]$Folder.shared) {
                "Cartella condivisa | destinatari: $([int]$Folder.share_recipient_count) | permessi: $([int]$Folder.share_permission_count) | ID: $($Folder.id)"
            } else {
                "Cartella personale | ID: $($Folder.id)"
            }
            [void]$DestinationFolder.Items.Add($Item)
            if ([string]$Folder.id -eq $SelectedId) {
                $SelectedIndex = $DestinationFolder.Items.Count - 1
            }
        }
        $DestinationFolder.SelectedIndex = $SelectedIndex
    } finally {
        $script:PopulatingDestinationFolders = $false
    }
    Update-DestinationControlState
}

function Show-ClientDestinationMappingDialog([switch]$BuildOnly) {
    if (-not $script:DestinationFolderCatalogLoaded) {
        [System.Windows.MessageBox]::Show("Eseguire prima il dry-run per caricare le cartelle Passbolt accessibili.", "Cartelle non caricate", "OK", "Information") | Out-Null
        return
    }
    $Clients = @(Get-RequiredImportClients)
    if ($Clients.Count -lt 1) { return }

    $Dialog = New-Object System.Windows.Window
    $Dialog.Title = "Mappatura clienti - Passbolt"
    $Dialog.Width = 820
    $Dialog.Height = [Math]::Min(700, 230 + ($Clients.Count * 50))
    $Dialog.MinWidth = 660
    $Dialog.MinHeight = 320
    $Dialog.WindowStartupLocation = "CenterOwner"
    if (-not $BuildOnly -and $Window.IsVisible) { $Dialog.Owner = $Window }
    Initialize-ModernDialog $Dialog

    $Layout = New-Object System.Windows.Controls.Grid
    $Layout.Margin = [System.Windows.Thickness]::new(20)
    $HeaderRow = New-Object System.Windows.Controls.RowDefinition
    $HeaderRow.Height = [System.Windows.GridLength]::Auto
    $ContentRow = New-Object System.Windows.Controls.RowDefinition
    $ContentRow.Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $FooterRow = New-Object System.Windows.Controls.RowDefinition
    $FooterRow.Height = [System.Windows.GridLength]::Auto
    [void]$Layout.RowDefinitions.Add($HeaderRow)
    [void]$Layout.RowDefinitions.Add($ContentRow)
    [void]$Layout.RowDefinitions.Add($FooterRow)

    $Header = New-Object System.Windows.Controls.StackPanel
    $Header.Margin = [System.Windows.Thickness]::new(0, 0, 0, 14)
    $Title = New-Object System.Windows.Controls.TextBlock
    $Title.Text = "Destinazione Passbolt per ogni cliente"
    $Title.FontSize = 20
    $Title.FontWeight = "Bold"
    $Title.Foreground = Get-Brush "#1F2933"
    [void]$Header.Children.Add($Title)
    $Description = New-Object System.Windows.Controls.TextBlock
    $Description.Text = "Ogni cliente deve essere associato esplicitamente a una cartella scrivibile o alla radice. Per le cartelle condivise verranno ereditati i permessi e cifrata una copia del segreto per ogni destinatario verificato."
    $Description.TextWrapping = "Wrap"
    $Description.Foreground = Get-Brush "#66737F"
    $Description.Margin = [System.Windows.Thickness]::new(0, 5, 0, 0)
    [void]$Header.Children.Add($Description)
    [System.Windows.Controls.Grid]::SetRow($Header, 0)
    [void]$Layout.Children.Add($Header)

    $Border = New-Object System.Windows.Controls.Border
    $Border.Background = Get-Brush "#FFFFFF"
    $Border.BorderBrush = Get-Brush "#DDE3E8"
    $Border.BorderThickness = [System.Windows.Thickness]::new(1)
    $Border.CornerRadius = [System.Windows.CornerRadius]::new(5)
    $Border.Padding = [System.Windows.Thickness]::new(12)
    [System.Windows.Controls.Grid]::SetRow($Border, 1)
    $Scroll = New-Object System.Windows.Controls.ScrollViewer
    $Scroll.VerticalScrollBarVisibility = "Auto"
    $Rows = New-Object System.Windows.Controls.StackPanel
    $Editors = @{}
    foreach ($Client in $Clients) {
        $Row = New-Object System.Windows.Controls.Grid
        $Row.Margin = [System.Windows.Thickness]::new(0, 4, 0, 4)
        $ClientColumn = New-Object System.Windows.Controls.ColumnDefinition
        $ClientColumn.Width = [System.Windows.GridLength]::new(220)
        $FolderColumn = New-Object System.Windows.Controls.ColumnDefinition
        $FolderColumn.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
        [void]$Row.ColumnDefinitions.Add($ClientColumn)
        [void]$Row.ColumnDefinitions.Add($FolderColumn)

        $ClientLabel = New-Object System.Windows.Controls.TextBlock
        $ClientLabel.Text = $Client
        $ClientLabel.VerticalAlignment = "Center"
        $ClientLabel.FontWeight = "SemiBold"
        $ClientLabel.Foreground = Get-Brush "#1F2933"
        $ClientLabel.ToolTip = $Client
        [System.Windows.Controls.Grid]::SetColumn($ClientLabel, 0)
        [void]$Row.Children.Add($ClientLabel)

        $Combo = New-Object System.Windows.Controls.ComboBox
        $Combo.MinWidth = 360
        $Combo.MaxDropDownHeight = 320
        $Combo.Margin = [System.Windows.Thickness]::new(12, 0, 0, 0)
        $UnassignedItem = New-Object System.Windows.Controls.ComboBoxItem
        $UnassignedItem.Content = "Selezionare una destinazione..."
        $UnassignedItem.Tag = "__unassigned__"
        [void]$Combo.Items.Add($UnassignedItem)
        $RootItem = New-Object System.Windows.Controls.ComboBoxItem
        $RootItem.Content = "Radice personale Passbolt"
        $RootItem.Tag = "__root__"
        [void]$Combo.Items.Add($RootItem)
        $SelectedIndex = 0
        $CurrentValue = if ($script:ClientDestinationMap.ContainsKey($Client)) { [string]$script:ClientDestinationMap[$Client] } else { "" }
        if ($CurrentValue -eq "__root__") { $SelectedIndex = 1 }
        foreach ($Folder in @($script:AvailableDestinationFolders)) {
            $Item = New-Object System.Windows.Controls.ComboBoxItem
            $Item.Content = Get-DestinationFolderDisplayText $Folder
            $Item.Tag = [string]$Folder.id
            $Item.ToolTip = if ([bool]$Folder.shared) {
                "Cartella condivisa | destinatari: $([int]$Folder.share_recipient_count) | permessi: $([int]$Folder.share_permission_count) | ID: $($Folder.id)"
            } else {
                "Cartella personale | ID: $($Folder.id)"
            }
            [void]$Combo.Items.Add($Item)
            if ([string]$Folder.id -eq $CurrentValue) {
                $SelectedIndex = $Combo.Items.Count - 1
            }
        }
        $Combo.SelectedIndex = $SelectedIndex
        [System.Windows.Controls.Grid]::SetColumn($Combo, 1)
        [void]$Row.Children.Add($Combo)
        $Editors[$Client] = $Combo
        [void]$Rows.Children.Add($Row)
    }
    $Scroll.Content = $Rows
    $Border.Child = $Scroll
    [void]$Layout.Children.Add($Border)

    $Footer = New-Object System.Windows.Controls.StackPanel
    $Footer.Orientation = "Horizontal"
    $Footer.HorizontalAlignment = "Right"
    $Footer.Margin = [System.Windows.Thickness]::new(0, 14, 0, 0)
    [System.Windows.Controls.Grid]::SetRow($Footer, 2)
    $CancelButton = New-Object System.Windows.Controls.Button
    $CancelButton.Content = "Annulla"
    $CancelButton.Padding = [System.Windows.Thickness]::new(18, 8, 18, 8)
    $CancelButton.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $CancelButton.Add_Click({ $Dialog.DialogResult = $false })
    [void]$Footer.Children.Add($CancelButton)
    $SaveButton = New-Object System.Windows.Controls.Button
    $SaveButton.Content = "Salva mappatura"
    $SaveButton.Padding = [System.Windows.Thickness]::new(18, 8, 18, 8)
    $SaveButton.Style = $Window.FindResource("PrimaryButton")
    $SaveButton.Foreground = Get-Brush "#FFFFFF"
    $SaveButton.BorderThickness = [System.Windows.Thickness]::new(0)
    $SaveButton.Add_Click({
        $Missing = @($Clients | Where-Object {
            $null -eq $Editors[$_].SelectedItem -or [string]$Editors[$_].SelectedItem.Tag -eq "__unassigned__"
        })
        if ($Missing.Count -gt 0) {
            [System.Windows.MessageBox]::Show("Selezionare una destinazione per tutti i clienti. Mancanti: $($Missing -join ', ')", "Mappatura incompleta", "OK", "Warning") | Out-Null
            return
        }
        $Dialog.DialogResult = $true
    })
    [void]$Footer.Children.Add($SaveButton)
    [void]$Layout.Children.Add($Footer)
    $Dialog.Content = $Layout

    if ($BuildOnly) {
        return [pscustomobject]@{ Window = $Dialog; Editors = $Editors }
    }

    if ($Dialog.ShowDialog() -ne $true) { return }
    $NewMap = @{}
    foreach ($Client in $Clients) {
        $NewMap[$Client] = [string]$Editors[$Client].SelectedItem.Tag
    }
    $script:ClientDestinationMap = $NewMap
    Reset-ImportPlan "Mappatura clienti modificata. Ripetere il dry-run autenticato."
    Update-ClientMappingButtonState
    Add-Activity "Mappatura Passbolt configurata per $($Clients.Count) clienti; il piano precedente e' stato invalidato."
}

function Reset-ImportWorkflow {
    $script:ImportCandidates = @()
    $script:ImportSecretOverrides = @{}
    $script:ImportSourceFilePasswords = @{}
    $script:ClientDestinationMap = @{}
    Clear-RecoveryCandidateState
    $ImportMetricSelected.Text = [string][char]0x2014
    $ImportSummary.Text = "Prepara i candidati dalla revisione"
    Reset-ImportPlan
    Reset-RecoveryPlan "Rivedi i documenti sorgente, quindi seleziona il lotto da associare."
    $StepImportNumber.Foreground = Get-Brush "#8E8E93"
    $StepImportText.Foreground = Get-Brush "#8E8E93"
    Update-ClientMappingButtonState
    Update-ImportSessionState
}

function Get-ReviewCandidateRequest($Row, [switch]$ForReveal) {
    $PasswordOverridden = if ($ForReveal) { $false } else { [bool]$Row.PasswordOverridden }
    return [pscustomobject][ordered]@{
        candidate_id = [string]$Row.CandidateId
        source_relative_path = [string]$Row.SourceRelativePath
        source_sha256 = [string]$Row.SourceHash
        client = [string]$Row.Client
        source_at_root = ([string]$Row.Client).Trim().Equals("(radice)", [StringComparison]::OrdinalIgnoreCase)
        title = [string]$Row.Title
        username = [string]$Row.Username
        uri = [string]$Row.Uri
        reviewed_client = [string]$Row.OriginalClient
        reviewed_source_at_root = [bool]$Row.OriginalSourceAtRoot
        reviewed_title = [string]$Row.OriginalTitle
        reviewed_username = [string]$Row.OriginalUsername
        reviewed_uri = [string]$Row.OriginalUri
        password_overridden = $PasswordOverridden
        source_password_required = [bool]$Row.SourcePasswordRequired
        source_mapping_digest = [string]$Row.SourceMappingDigest
        source_mapping_profile = $Row.SourceMappingProfile
    }
}

function Get-ReviewSourceFilePasswordPayload([object[]]$Rows) {
    $Payload = New-Object System.Collections.Generic.List[object]
    $Seen = @{}
    foreach ($Row in @($Rows | Where-Object { [bool]$_.SourcePasswordRequired })) {
        $RelativePath = [string]$Row.SourceRelativePath
        if ($Seen.ContainsKey($RelativePath)) { continue }
        if (-not $script:ReviewFilePasswords.ContainsKey($RelativePath) -or -not [string]$script:ReviewFilePasswords[$RelativePath]) {
            throw "La password del file Excel $RelativePath non e' piu disponibile in memoria. Ripetere la revisione."
        }
        $Payload.Add([pscustomobject][ordered]@{
            relative_path = $RelativePath
            password = [string]$script:ReviewFilePasswords[$RelativePath]
        })
        $Seen[$RelativePath] = $true
    }
    return $Payload.ToArray()
}

function Get-CandidateSourceFilePasswordPayload([object[]]$Candidates, [hashtable]$PasswordMap) {
    $Payload = New-Object System.Collections.Generic.List[object]
    $Seen = @{}
    foreach ($Candidate in @($Candidates | Where-Object { [bool]$_.source_password_required })) {
        $RelativePath = [string]$Candidate.source_relative_path
        if ($Seen.ContainsKey($RelativePath)) { continue }
        if ($null -eq $PasswordMap -or -not $PasswordMap.ContainsKey($RelativePath) -or -not [string]$PasswordMap[$RelativePath]) {
            throw "La password del file Excel $RelativePath non e' piu disponibile in memoria. Tornare alla revisione."
        }
        $Payload.Add([pscustomobject][ordered]@{
            relative_path = $RelativePath
            password = [string]$PasswordMap[$RelativePath]
        })
        $Seen[$RelativePath] = $true
    }
    return $Payload.ToArray()
}

function Get-ImportSourceFilePasswordPayload([object[]]$Candidates) {
    return @(Get-CandidateSourceFilePasswordPayload $Candidates $script:ImportSourceFilePasswords)
}

function Update-ReviewRowState($Row) {
    $Client = ([string]$Row.Client).Trim()
    $Title = ([string]$Row.Title).Trim()
    $Username = ([string]$Row.Username).Trim()
    $Uri = ([string]$Row.Uri).Trim()
    $PasswordAvailable = [bool]$Row.SecretPresent -or [bool]$Row.PasswordOverridden
    $Ready = (
        $PasswordAvailable -and
        $Client.Length -gt 0 -and $Client.Length -le 256 -and
        $Title.Length -gt 0 -and $Title.Length -le 255 -and
        $Username.Length -le 255 -and $Uri.Length -le 2048 -and
        ($Username.Length -gt 0 -or $Uri.Length -gt 0)
    )
    $Row.Status = if ($Ready) { "ready" } else { "incomplete" }
    $Row.IsEdited = (
        $Client -cne [string]$Row.OriginalClient -or
        $Title -cne [string]$Row.OriginalTitle -or
        $Username -cne [string]$Row.OriginalUsername -or
        $Uri -cne [string]$Row.OriginalUri -or
        [bool]$Row.PasswordOverridden
    )
    if ($Ready) {
        $Row.StatusLabel = if ([bool]$Row.IsEdited) { "Pronto (modificato)" } else { "Pronto" }
    } else {
        $Row.StatusLabel = if ([bool]$Row.IsEdited) { "Da completare (modificato)" } else { "Da completare" }
    }
    if ($script:ReviewPasswordsVisible -and ([bool]$Row.PasswordOverridden -or [bool]$Row.SecretCachedFromSource)) {
        $Row.SecretDisplay = [string]$Row.SecretValue
    } elseif ($PasswordAvailable) {
        $Length = if ([bool]$Row.PasswordOverridden) { ([string]$Row.SecretValue).Length } else { [int]$Row.SecretLength }
        $Row.SecretDisplay = "******** ($Length)"
    } else {
        $Row.SecretDisplay = "Mancante"
    }
}

function Update-ReviewMetrics {
    $ReadyCount = @($script:AllReviewRows | Where-Object { $_.Status -eq "ready" }).Count
    $IncompleteCount = $script:AllReviewRows.Count - $ReadyCount
    $ReviewMetricCandidates.Text = [string]$script:AllReviewRows.Count
    $ReviewMetricReady.Text = [string]$ReadyCount
    $ReviewMetricIncomplete.Text = [string]$IncompleteCount
}

function Update-ReviewPasswordVisibilityUi {
    foreach ($Row in $script:AllReviewRows) { Update-ReviewRowState $Row }
    $ReviewPasswordState.Text = if ($script:ReviewPasswordsVisible) { "PASSWORD VISIBILI" } else { "PASSWORD MASCHERATE" }
    $ReviewPasswordState.Foreground = if ($script:ReviewPasswordsVisible) { Get-Brush "#D70015" } else { Get-Brush "#248A3D" }
    $ReviewPasswordToggle.Content = if ($script:ReviewPasswordsVisible) { "Nascondi password" } else { "Mostra password" }
    if ([bool]$ReviewPasswordToggle.IsChecked -ne $script:ReviewPasswordsVisible) {
        $script:UpdatingReviewPasswordToggle = $true
        try { $ReviewPasswordToggle.IsChecked = $script:ReviewPasswordsVisible } finally { $script:UpdatingReviewPasswordToggle = $false }
    }
    $ReviewCandidatesGrid.Items.Refresh()
}

function Clear-ReviewSourceSecretCache {
    foreach ($Row in $script:AllReviewRows) {
        if (-not [bool]$Row.PasswordOverridden) {
            $Row.SecretValue = ""
            $Row.SecretCachedFromSource = $false
        }
    }
}

function Read-ReviewSourceSecretsAsync(
    [object[]]$Rows,
    [scriptblock]$OnCompleted,
    [object]$CallbackContext = $null
) {
    $PendingRows = @($Rows | Where-Object {
        [bool]$_.SecretPresent -and -not [bool]$_.PasswordOverridden -and -not [bool]$_.SecretCachedFromSource
    })
    if ($PendingRows.Count -lt 1) {
        & $OnCompleted $true $CallbackContext
        return
    }
    try {
        $SourceFilePasswords = @(Get-ReviewSourceFilePasswordPayload $PendingRows)
        $SecureRequest = [pscustomobject]@{
            candidates = @($PendingRows | ForEach-Object { Get-ReviewCandidateRequest $_ -ForReveal })
            source_file_passwords = $SourceFilePasswords
        }
        $OperationParameters = @{
            Name = "Lettura temporanea segreti locali"
            Category = "read"
            WorkKind = "SecureJsonProcess"
            Payload = New-SecureJsonOperationPayload $PythonExecutable @($ImportScript, "--reveal", "--root", $script:InventoryFolder) $SecureRequest 180000
            Context = [pscustomobject]@{
                Rows = $PendingRows
                OnCompleted = $OnCompleted
                CallbackContext = $CallbackContext
            }
            OnSuccess = {
                param($Envelope, $Operation)
                $Succeeded = $false
                $FailureMessage = ""
                $ById = @{}
                try {
                    if (-not [bool]$Envelope.ok) { throw (Get-SecureErrorMessage $Envelope) }
                    foreach ($SecretItem in @($Envelope.result.secrets)) {
                        $ById[[string]$SecretItem.candidate_id] = [string]$SecretItem.password
                    }
                    foreach ($Row in @($Operation.Context.Rows)) {
                        if (-not $ById.ContainsKey([string]$Row.CandidateId)) { throw "La password richiesta non e' stata restituita dalla lettura locale." }
                        $Row.SecretValue = [string]$ById[[string]$Row.CandidateId]
                        $Row.SecretCachedFromSource = $true
                    }
                    $Succeeded = $true
                } catch {
                    $FailureMessage = [string]$_.Exception.Message
                } finally {
                    $ById.Clear()
                    if ($null -ne $Envelope.result) { $Envelope.result.secrets = $null }
                }
                if (-not $Succeeded) {
                    Clear-ReviewSourceSecretCache
                    [System.Windows.MessageBox]::Show($FailureMessage, "Password non disponibili", "OK", "Error") | Out-Null
                }
                & $Operation.Context.OnCompleted $Succeeded $Operation.Context.CallbackContext
            }
            OnFailure = {
                param($FailureMessage, $Operation)
                Clear-ReviewSourceSecretCache
                [System.Windows.MessageBox]::Show($FailureMessage, "Password non disponibili", "OK", "Error") | Out-Null
                & $Operation.Context.OnCompleted $false $Operation.Context.CallbackContext
            }
        }
        [void](Start-UiOperation @OperationParameters)
    } catch {
        Clear-OperationalSensitivePayload ([pscustomobject]@{ InputObject = $SecureRequest })
        Clear-ReviewSourceSecretCache
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Password non disponibili", "OK", "Error") | Out-Null
        & $OnCompleted $false $CallbackContext
    }
}

function Set-ReviewPasswordsVisible([bool]$Visible, [switch]$SkipPrompt) {
    if ($Visible -and -not $script:ReviewPasswordsVisible) {
        if (-not $SkipPrompt) {
            $Decision = [System.Windows.MessageBox]::Show(
                "Le password dei candidati verranno rilette dai file verificati e mostrate in chiaro sullo schermo. Rimarranno soltanto nella memoria della sessione e non saranno salvate o registrate. Continuare?",
                "Mostra password",
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Warning
            )
            if ($Decision -ne [System.Windows.MessageBoxResult]::Yes) {
                $script:UpdatingReviewPasswordToggle = $true
                try { $ReviewPasswordToggle.IsChecked = $false } finally { $script:UpdatingReviewPasswordToggle = $false }
                return
            }
        }
        Read-ReviewSourceSecretsAsync $script:AllReviewRows {
            param($Succeeded, $Context)
            $script:ReviewPasswordsVisible = [bool]$Succeeded
            if ($Succeeded) {
                Add-Activity "Visualizzazione temporanea delle password attivata; nessun valore segreto e' stato registrato."
            } else {
                Clear-ReviewSourceSecretCache
            }
            Update-ReviewPasswordVisibilityUi
        }
        return
    }
    if (-not $Visible) {
        $script:ReviewPasswordsVisible = $false
        Clear-ReviewSourceSecretCache
    }
    Update-ReviewPasswordVisibilityUi
}
function Show-ReviewCandidateEditor($Row = $null, [switch]$BuildOnly) {
    if ($null -eq $Row) {
        $Selected = @($ReviewCandidatesGrid.SelectedItems)
        if ($Selected.Count -ne 1) { return }
        $Row = $Selected[0]
    }
    if (-not $BuildOnly -and [bool]$Row.SecretPresent -and -not [bool]$Row.PasswordOverridden -and -not [bool]$Row.SecretCachedFromSource) {
        Read-ReviewSourceSecretsAsync @($Row) {
            param($Succeeded, $RowContext)
            if ($Succeeded) { Show-ReviewCandidateEditor $RowContext }
        } $Row
        return
    }

    $Dialog = New-Object System.Windows.Window
    $Dialog.Title = "Modifica candidato - Passbolt"
    $Dialog.Width = 670
    $Dialog.Height = 520
    $Dialog.MinWidth = 570
    $Dialog.MinHeight = 480
    $Dialog.WindowStartupLocation = "CenterOwner"
    if (-not $BuildOnly -and $Window.IsVisible) { $Dialog.Owner = $Window }
    Initialize-ModernDialog $Dialog

    $Layout = New-Object System.Windows.Controls.Grid
    $Layout.Margin = [System.Windows.Thickness]::new(22)
    foreach ($Height in @("Auto", "*", "Auto", "Auto")) {
        $Definition = New-Object System.Windows.Controls.RowDefinition
        $Definition.Height = if ($Height -eq "*") { [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) } else { [System.Windows.GridLength]::Auto }
        [void]$Layout.RowDefinitions.Add($Definition)
    }

    $Header = New-Object System.Windows.Controls.StackPanel
    $Header.Margin = [System.Windows.Thickness]::new(0, 0, 0, 14)
    $HeaderTitle = New-Object System.Windows.Controls.TextBlock
    $HeaderTitle.Text = "Correggi i dati prima dell'importazione"
    $HeaderTitle.FontSize = 20
    $HeaderTitle.FontWeight = "Bold"
    $HeaderText = New-Object System.Windows.Controls.TextBlock
    $HeaderText.Text = "Le modifiche saranno usate nel dry-run e nella risorsa Passbolt. Il file sorgente non verra' modificato."
    $HeaderText.TextWrapping = "Wrap"
    $HeaderText.Foreground = Get-Brush "#66737F"
    $HeaderText.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
    [void]$Header.Children.Add($HeaderTitle)
    [void]$Header.Children.Add($HeaderText)
    [void]$Layout.Children.Add($Header)

    $FormBorder = New-Object System.Windows.Controls.Border
    $FormBorder.Background = Get-Brush "#FFFFFF"
    $FormBorder.BorderBrush = Get-Brush "#DDE3E8"
    $FormBorder.BorderThickness = [System.Windows.Thickness]::new(1)
    $FormBorder.CornerRadius = [System.Windows.CornerRadius]::new(5)
    $FormBorder.Padding = [System.Windows.Thickness]::new(16)
    [System.Windows.Controls.Grid]::SetRow($FormBorder, 1)
    $Form = New-Object System.Windows.Controls.Grid
    $LabelColumn = New-Object System.Windows.Controls.ColumnDefinition
    $LabelColumn.Width = [System.Windows.GridLength]::new(120)
    $EditorColumn = New-Object System.Windows.Controls.ColumnDefinition
    $EditorColumn.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    [void]$Form.ColumnDefinitions.Add($LabelColumn)
    [void]$Form.ColumnDefinitions.Add($EditorColumn)
    1..5 | ForEach-Object {
        $Definition = New-Object System.Windows.Controls.RowDefinition
        $Definition.Height = [System.Windows.GridLength]::Auto
        [void]$Form.RowDefinitions.Add($Definition)
    }

    $Editors = @{}
    $FieldSpecs = @(
        @("Cliente", "Client", [string]$Row.Client, 256),
        @("Titolo", "Title", [string]$Row.Title, 255),
        @("Username", "Username", [string]$Row.Username, 255),
        @("URL / host", "Uri", [string]$Row.Uri, 2048)
    )
    for ($Index = 0; $Index -lt $FieldSpecs.Count; $Index++) {
        $Spec = $FieldSpecs[$Index]
        $Label = New-Object System.Windows.Controls.TextBlock
        $Label.Text = [string]$Spec[0]
        $Label.VerticalAlignment = "Center"
        $Label.FontWeight = "SemiBold"
        $Label.Margin = [System.Windows.Thickness]::new(0, 0, 10, 10)
        [System.Windows.Controls.Grid]::SetRow($Label, $Index)
        [void]$Form.Children.Add($Label)
        $Editor = New-Object System.Windows.Controls.TextBox
        $Editor.Text = [string]$Spec[2]
        $Editor.MaxLength = [int]$Spec[3]
        $Editor.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
        [System.Windows.Automation.AutomationProperties]::SetName($Editor, [string]$Spec[0])
        [System.Windows.Controls.Grid]::SetRow($Editor, $Index)
        [System.Windows.Controls.Grid]::SetColumn($Editor, 1)
        [void]$Form.Children.Add($Editor)
        $Editors[[string]$Spec[1]] = $Editor
    }

    $PasswordLabel = New-Object System.Windows.Controls.TextBlock
    $PasswordLabel.Text = "Password"
    $PasswordLabel.VerticalAlignment = "Top"
    $PasswordLabel.FontWeight = "SemiBold"
    $PasswordLabel.Margin = [System.Windows.Thickness]::new(0, 8, 10, 0)
    [System.Windows.Controls.Grid]::SetRow($PasswordLabel, 4)
    [void]$Form.Children.Add($PasswordLabel)
    $PasswordPanel = New-Object System.Windows.Controls.Grid
    $PasswordEditorRow = New-Object System.Windows.Controls.RowDefinition
    $PasswordEditorRow.Height = [System.Windows.GridLength]::Auto
    $PasswordToggleRow = New-Object System.Windows.Controls.RowDefinition
    $PasswordToggleRow.Height = [System.Windows.GridLength]::Auto
    [void]$PasswordPanel.RowDefinitions.Add($PasswordEditorRow)
    [void]$PasswordPanel.RowDefinitions.Add($PasswordToggleRow)
    $PasswordBox = New-Object System.Windows.Controls.PasswordBox
    $PasswordBox.MaxLength = 65536
    $PasswordBox.Password = [string]$Row.SecretValue
    [System.Windows.Automation.AutomationProperties]::SetName($PasswordBox, "Password candidato")
    $PasswordText = New-Object System.Windows.Controls.TextBox
    $PasswordText.MaxLength = 65536
    $PasswordText.Text = [string]$Row.SecretValue
    $PasswordText.Visibility = "Collapsed"
    [System.Windows.Automation.AutomationProperties]::SetName($PasswordText, "Password candidato visibile")
    $ShowPassword = New-Object System.Windows.Controls.CheckBox
    $ShowPassword.Content = "Mostra password durante la modifica"
    $ShowPassword.Margin = [System.Windows.Thickness]::new(0, 7, 0, 0)
    [System.Windows.Controls.Grid]::SetRow($ShowPassword, 1)
    $ShowPassword.Add_Checked({
        $PasswordText.Text = $PasswordBox.Password
        $PasswordBox.Visibility = "Collapsed"
        $PasswordText.Visibility = "Visible"
    })
    $ShowPassword.Add_Unchecked({
        $PasswordBox.Password = $PasswordText.Text
        $PasswordText.Visibility = "Collapsed"
        $PasswordBox.Visibility = "Visible"
    })
    [void]$PasswordPanel.Children.Add($PasswordBox)
    [void]$PasswordPanel.Children.Add($PasswordText)
    [void]$PasswordPanel.Children.Add($ShowPassword)
    [System.Windows.Controls.Grid]::SetRow($PasswordPanel, 4)
    [System.Windows.Controls.Grid]::SetColumn($PasswordPanel, 1)
    [void]$Form.Children.Add($PasswordPanel)
    $Editors["Password"] = $PasswordBox
    $FormBorder.Child = $Form
    [void]$Layout.Children.Add($FormBorder)

    $Notice = New-Object System.Windows.Controls.TextBlock
    $Notice.Text = "La password resta soltanto nella memoria della sessione e non viene scritta nel registro."
    $Notice.Foreground = Get-Brush "#66737F"
    $Notice.FontSize = 11
    $Notice.Margin = [System.Windows.Thickness]::new(0, 10, 0, 0)
    [System.Windows.Controls.Grid]::SetRow($Notice, 2)
    [void]$Layout.Children.Add($Notice)

    $Footer = New-Object System.Windows.Controls.StackPanel
    $Footer.Orientation = "Horizontal"
    $Footer.HorizontalAlignment = "Right"
    $Footer.Margin = [System.Windows.Thickness]::new(0, 14, 0, 0)
    [System.Windows.Controls.Grid]::SetRow($Footer, 3)
    $CancelButton = New-Object System.Windows.Controls.Button
    $CancelButton.Content = "Annulla"
    $CancelButton.Padding = [System.Windows.Thickness]::new(18, 8, 18, 8)
    $CancelButton.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $CancelButton.Add_Click({ $Dialog.DialogResult = $false })
    $SaveButton = New-Object System.Windows.Controls.Button
    $SaveButton.Content = "Salva modifiche"
    $SaveButton.Padding = [System.Windows.Thickness]::new(18, 8, 18, 8)
    $SaveButton.Style = $Window.FindResource("PrimaryButton")
    $SaveButton.Foreground = Get-Brush "#FFFFFF"
    $SaveButton.BorderThickness = [System.Windows.Thickness]::new(0)
    $SaveButton.Add_Click({
        $Password = if ([bool]$ShowPassword.IsChecked) { [string]$PasswordText.Text } else { [string]$PasswordBox.Password }
        $Client = $Editors.Client.Text.Trim()
        $Title = $Editors.Title.Text.Trim()
        $Username = $Editors.Username.Text.Trim()
        $Uri = $Editors.Uri.Text.Trim()
        if (-not $Client -or -not $Title -or -not $Password) {
            [System.Windows.MessageBox]::Show("Cliente, titolo e password sono obbligatori.", "Dati incompleti", "OK", "Warning") | Out-Null
            return
        }
        if (-not $Username -and -not $Uri) {
            [System.Windows.MessageBox]::Show("Inserire almeno uno fra username e URL/host.", "Dati incompleti", "OK", "Warning") | Out-Null
            return
        }
        $Dialog.Tag = [pscustomobject]@{ Client = $Client; Title = $Title; Username = $Username; Uri = $Uri; Password = $Password }
        $Dialog.DialogResult = $true
    })
    [void]$Footer.Children.Add($CancelButton)
    [void]$Footer.Children.Add($SaveButton)
    [void]$Layout.Children.Add($Footer)
    $Dialog.Content = $Layout

    if ($BuildOnly) {
        return [pscustomobject]@{ Window = $Dialog; Editors = $Editors; PasswordText = $PasswordText; ShowPassword = $ShowPassword }
    }

    $OriginalPassword = [string]$Row.SecretValue
    if ($Dialog.ShowDialog() -ne $true) {
        if (-not $script:ReviewPasswordsVisible -and -not [bool]$Row.PasswordOverridden) {
            $Row.SecretValue = ""
            $Row.SecretCachedFromSource = $false
            Update-ReviewRowState $Row
        }
        return
    }
    $Result = $Dialog.Tag
    $Row.Client = [string]$Result.Client
    $Row.Title = [string]$Result.Title
    $Row.Username = [string]$Result.Username
    $Row.Uri = [string]$Result.Uri
    $Row.PasswordOverridden = (-not [bool]$Row.SecretPresent) -or -not [string]::Equals([string]$Result.Password, $OriginalPassword, [StringComparison]::Ordinal)
    $Row.SecretValue = [string]$Result.Password
    $Row.SecretCachedFromSource = -not [bool]$Row.PasswordOverridden
    if (-not $script:ReviewPasswordsVisible -and -not [bool]$Row.PasswordOverridden) {
        $Row.SecretValue = ""
        $Row.SecretCachedFromSource = $false
    }
    Update-ReviewRowState $Row
    Update-ReviewMetrics
    Reset-ImportWorkflow
    Apply-ReviewFilters
    Add-Activity "Candidato $($Row.CandidateId) modificato in memoria; nessun valore segreto e' stato registrato."
}

function Update-ImportSelectionState {
    $Selected = @($ReviewCandidatesGrid.SelectedItems)
    $ReadyCount = @($Selected | Where-Object { $_.Status -eq "ready" }).Count
    $AllReady = ($Selected.Count -gt 0 -and $ReadyCount -eq $Selected.Count)
    $PrepareImportButton.Content = "Prepara importazione ($($Selected.Count))"
    $PrepareImportButton.IsEnabled = $AllReady
    $EditReviewCandidateButton.IsEnabled = ($Selected.Count -eq 1)
    if ($Selected.Count -gt 0 -and -not $AllReady) {
        $PrepareImportButton.Content = "Seleziona solo candidati pronti"
    }
}

function Test-ImportPlanCanImport([object]$Result) {
    if ($null -eq $Result) { return $false }
    $CanImportProperty = $Result.PSObject.Properties["can_import"]
    if (-not (
        $null -ne $CanImportProperty -and
        $CanImportProperty.Value -is [bool] -and
        [bool]$CanImportProperty.Value
    )) { return $false }

    $PreflightStatusProperty = $Result.PSObject.Properties["preflight_status"]
    if (
        $null -eq $PreflightStatusProperty -or
        -not ($PreflightStatusProperty.Value -is [string]) -or
        [string]$PreflightStatusProperty.Value -notin @("passed", "warning")
    ) { return $false }

    $PreflightChecksProperty = $Result.PSObject.Properties["preflight_checks"]
    if ($null -eq $PreflightChecksProperty -or -not ($PreflightChecksProperty.Value -is [System.Array])) {
        return $false
    }
    foreach ($Check in @($PreflightChecksProperty.Value)) {
        if ($null -eq $Check) { return $false }
        $StatusProperty = $Check.PSObject.Properties["status"]
        $IdProperty = $Check.PSObject.Properties["id"]
        if (
            $null -eq $StatusProperty -or
            $null -eq $IdProperty -or
            -not ($StatusProperty.Value -is [string]) -or
            -not ($IdProperty.Value -is [string]) -or
            [string]::IsNullOrWhiteSpace([string]$IdProperty.Value) -or
            [string]$StatusProperty.Value -notin @("passed", "warning", "not_required")
        ) { return $false }
    }

    $CreateCountProperty = $Result.PSObject.Properties["create_count"]
    if ($null -eq $CreateCountProperty -or -not ($CreateCountProperty.Value -is [int] -or $CreateCountProperty.Value -is [long])) {
        return $false
    }
    $CreateCount = [long]$CreateCountProperty.Value
    $CandidatesProperty = $Result.PSObject.Properties["candidates"]
    if (
        $CreateCount -lt 0 -or
        $null -eq $CandidatesProperty -or
        -not ($CandidatesProperty.Value -is [System.Array]) -or
        $CreateCount -gt @($CandidatesProperty.Value).Count
    ) { return $false }

    $PlanDigestProperty = $Result.PSObject.Properties["plan_digest"]
    if (
        $null -eq $PlanDigestProperty -or
        -not ($PlanDigestProperty.Value -is [string]) -or
        [string]$PlanDigestProperty.Value -notmatch '^[0-9a-f]{64}$'
    ) { return $false }

    $UnavailableReasonProperty = $Result.PSObject.Properties["unavailable_reason"]
    return (
        $null -ne $UnavailableReasonProperty -and
        ($null -eq $UnavailableReasonProperty.Value -or [string]::IsNullOrWhiteSpace([string]$UnavailableReasonProperty.Value))
    )
}

function Get-ImportReadinessDiagnostic([object]$Result) {
    $MalformedCause = "Il risultato del preflight e' incompleto o malformato; la scrittura resta bloccata."
    if ($null -eq $Result) {
        return [pscustomobject]@{
            CanImport = $false
            Cause = $MalformedCause
            Hint = "Scrittura bloccata: $MalformedCause"
            ActivityCode = "preflight_result_invalid"
        }
    }

    $CanImportProperty = $Result.PSObject.Properties["can_import"]
    if ($null -eq $CanImportProperty -or -not ($CanImportProperty.Value -is [bool])) {
        return [pscustomobject]@{
            CanImport = $false
            Cause = $MalformedCause
            Hint = "Scrittura bloccata: $MalformedCause"
            ActivityCode = "preflight_result_invalid"
        }
    }
    if ([bool]$CanImportProperty.Value -and (Test-ImportPlanCanImport $Result)) {
        return [pscustomobject]@{
            CanImport = $true
            Cause = ""
            Hint = ""
            ActivityCode = "importable"
        }
    }
    if ([bool]$CanImportProperty.Value) {
        return [pscustomobject]@{
            CanImport = $false
            Cause = $MalformedCause
            Hint = "Scrittura bloccata: $MalformedCause"
            ActivityCode = "preflight_result_invalid"
        }
    }

    $BlockedCheckIds = @()
    $PreflightChecksProperty = $Result.PSObject.Properties["preflight_checks"]
    if ($null -ne $PreflightChecksProperty -and $PreflightChecksProperty.Value -is [System.Collections.IEnumerable]) {
        foreach ($Check in @($PreflightChecksProperty.Value)) {
            if ($null -eq $Check) { continue }
            $StatusProperty = $Check.PSObject.Properties["status"]
            $IdProperty = $Check.PSObject.Properties["id"]
            if (
                $null -ne $StatusProperty -and
                $null -ne $IdProperty -and
                $StatusProperty.Value -is [string] -and
                $IdProperty.Value -is [string] -and
                [string]$StatusProperty.Value -eq "blocked"
            ) {
                $BlockedCheckIds += [string]$IdProperty.Value
            }
        }
    }

    $BlockedCount = 0L
    $BlockedCountProperty = $Result.PSObject.Properties["blocked_count"]
    if ($null -ne $BlockedCountProperty -and ($BlockedCountProperty.Value -is [int] -or $BlockedCountProperty.Value -is [long])) {
        $CandidateBlockedCount = [long]$BlockedCountProperty.Value
        if ($CandidateBlockedCount -ge 0 -and $CandidateBlockedCount -le 1000000) {
            $BlockedCount = $CandidateBlockedCount
        }
    }

    $UnavailableReason = ""
    $UnavailableReasonProperty = $Result.PSObject.Properties["unavailable_reason"]
    if ($null -ne $UnavailableReasonProperty -and $UnavailableReasonProperty.Value -is [string]) {
        $UnavailableReason = [string]$UnavailableReasonProperty.Value
    }
    $KnownCapabilityReason = $UnavailableReason -match '^Il server non consente (?:un tipo password v4 compatibile|alcun tipo password v4 o v5 compatibile|cartelle v4|alcun formato cartella v4 o v5 compatibile)\.$'
    $KnownV5PolicyReason = $UnavailableReason -match '^Il profilo preview consente risorse v5 personali ma blocca le modifiche ACL necessarie per creare o condividere una risorsa v5 condivisa\.$'

    if ($BlockedCheckIds -contains "resource_format" -or $BlockedCheckIds -contains "folder_format" -or $KnownCapabilityReason) {
        $Cause = "Il server non dichiara le capability Passbolt richieste dal formato e dalla destinazione selezionati."
        $ActivityCode = "server_capability_missing"
    } elseif ($KnownV5PolicyReason) {
        $Cause = "Il profilo preview non consente import v5 condivisi o mutazioni ACL v5; scegliere una destinazione e permessi personali oppure usare risorse v4."
        $ActivityCode = "v5_acl_mutation_disabled"
    } elseif ($BlockedCount -gt 0 -or $BlockedCheckIds -contains "conflicts") {
        if ($BlockedCount -gt 0) {
            $Cause = "$BlockedCount credenziali esistono in una destinazione diversa o presentano conflitti o duplicati bloccanti. Il piano resta bloccato per evitare modifiche implicite."
        } else {
            $Cause = "Il preflight ha rilevato conflitti o duplicati bloccanti. Consultare il relativo controllo prima di riprovare."
        }
        $ActivityCode = "destination_conflict"
    } elseif ($BlockedCheckIds -contains "resource_catalog") {
        $Cause = "Il catalogo delle risorse non puo' essere confrontato in sicurezza per escludere duplicati o conflitti."
        $ActivityCode = "resource_catalog_unavailable"
    } elseif ($BlockedCheckIds -contains "folder_catalog") {
        $Cause = "Il catalogo delle cartelle non puo' essere verificato in sicurezza."
        $ActivityCode = "folder_catalog_unavailable"
    } elseif ($BlockedCheckIds -contains "destination_access") {
        $Cause = "La destinazione selezionata o la relativa ACL presenta un conflitto bloccante. Consultare il controllo di accesso alla destinazione."
        $ActivityCode = "destination_access_blocked"
    } elseif ($BlockedCheckIds -contains "permission_directory") {
        $Cause = "La directory autenticata necessaria per verificare i permessi non e' disponibile."
        $ActivityCode = "permission_directory_unavailable"
    } elseif ($BlockedCheckIds -contains "csrf_token") {
        $Cause = "Il token CSRF richiesto per una scrittura sicura non e' disponibile."
        $ActivityCode = "csrf_token_unavailable"
    } else {
        $Cause = "Il preflight ha restituito un requisito bloccante non classificabile; la scrittura resta disabilitata."
        $ActivityCode = "preflight_block_unclassified"
    }

    return [pscustomobject]@{
        CanImport = $false
        Cause = $Cause
        Hint = "Scrittura bloccata: $Cause"
        ActivityCode = $ActivityCode
    }
}

function Update-ExecuteImportState {
    $SessionReady = (
        (Test-ImportSessionActive) -and
        $script:ImportSessionRoot -eq $script:InventoryFolder -and
        [string]$script:ImportPlan.session_id -eq $script:ImportSessionId
    )
    $CanExecute = (
        $null -ne $script:ImportPlan -and
        $script:ConnectionVerified -and
        $SessionReady -and
        (Test-ImportPlanCanImport $script:ImportPlan) -and
        [int]$script:ImportPlan.create_count -gt 0 -and
        $ImportConfirmation.Text.Trim() -eq "IMPORTA $([int]$script:ImportPlan.create_count)"
    )
    $ExecuteImportButton.IsEnabled = $CanExecute
}

function Open-ImportPreparation {
    $Selected = @($ReviewCandidatesGrid.SelectedItems)
    if ($Selected.Count -lt 1) { return }
    if (@($Selected | Where-Object { $_.Status -ne "ready" }).Count -gt 0) {
        [System.Windows.MessageBox]::Show("La selezione contiene candidati da completare. Selezionare soltanto righe con stato Pronto.", "Selezione non importabile", "OK", "Warning") | Out-Null
        return
    }

    $Candidates = New-Object System.Collections.Generic.List[object]
    $script:ImportSecretOverrides = @{}
    $script:ImportSourceFilePasswords = @{}
    foreach ($Row in $Selected) {
        $Candidates.Add((Get-ReviewCandidateRequest $Row))
        if ([bool]$Row.SourcePasswordRequired) {
            $RelativePath = [string]$Row.SourceRelativePath
            if (-not $script:ReviewFilePasswords.ContainsKey($RelativePath) -or -not [string]$script:ReviewFilePasswords[$RelativePath]) {
                [System.Windows.MessageBox]::Show("La password del file Excel $RelativePath non e' piu disponibile in memoria. Ripetere la revisione.", "Password Excel non disponibile", "OK", "Error") | Out-Null
                $script:ImportSecretOverrides = @{}
                $script:ImportSourceFilePasswords = @{}
                return
            }
            $script:ImportSourceFilePasswords[$RelativePath] = [string]$script:ReviewFilePasswords[$RelativePath]
        }
        if ([bool]$Row.PasswordOverridden) {
            if (-not [string]$Row.SecretValue) {
                [System.Windows.MessageBox]::Show("La password modificata di un candidato non e' piu disponibile in memoria. Modificare nuovamente il candidato.", "Password non disponibile", "OK", "Error") | Out-Null
                $script:ImportSecretOverrides = @{}
                $script:ImportSourceFilePasswords = @{}
                return
            }
            $script:ImportSecretOverrides[[string]$Row.CandidateId] = [string]$Row.SecretValue
        }
    }
    $script:ImportCandidates = $Candidates.ToArray()
    $script:ClientDestinationMap = @{}
    $ImportMetricSelected.Text = [string]$script:ImportCandidates.Count
    $ImportSummary.Text = "$($script:ImportCandidates.Count) candidati pronti selezionati dalla revisione"
    Update-ClientMappingButtonState
    $PreparationStatus = if (Test-ImportSessionActive) {
        "Candidati preparati. La sessione e' attiva: configurare la destinazione ed eseguire il dry-run."
    } else {
        "Candidati preparati. Selezionare la chiave privata, inserire passphrase e MFA, quindi avviare la sessione."
    }
    Reset-ImportOperationalViews
    Reset-ImportPlan $PreparationStatus
    $StepImportNumber.Foreground = Get-Brush "#007AFF"
    $StepImportText.Foreground = Get-Brush "#3A3A3C"
    Add-Activity "Preparazione importazione: $($script:ImportCandidates.Count) candidati, nessun segreto registrato."
    Update-ImportSessionState
    Show-Phase04Workspace "new_import"
    Show-Page "Import"
    Refresh-RecoveryBatches -Quiet
}

function Set-ImportReadinessResult([object]$Result) {
    $script:ImportPlan = $Result
    $ReadinessDiagnostic = Get-ImportReadinessDiagnostic $Result
    $script:ImportPlanKeyPath = $script:ImportSessionKeyPath
    $script:PreflightReceiptEvidence = New-PreflightReceiptEvidence $Result
    $script:MigrationReceiptEvidence = $null
    $ExportPreflightReceiptButton.IsEnabled = $true
    $ExportMigrationReceiptButton.IsEnabled = $false
    $ImportConfirmation.Text = ""
    $ImportConfirmation.IsEnabled = $false
    $ExecuteImportButton.IsEnabled = $false
    Update-DestinationFolderOptions $Result.available_folders ([string]$Result.destination_folder_id)

    $PreflightRows = New-Object System.Collections.Generic.List[object]
    foreach ($Check in @($Result.preflight_checks)) {
        $StatusLabel = switch ([string]$Check.status) {
            "passed" { "Superato" }
            "warning" { "Attenzione" }
            "blocked" { "Bloccante" }
            "not_required" { "Non richiesto" }
            default { "Sconosciuto" }
        }
        $PreflightRows.Add([pscustomobject]@{
            CheckId = [string]$Check.id
            CheckLabel = [string]$Check.label
            Status = [string]$Check.status
            StatusLabel = $StatusLabel
            Detail = [string]$Check.detail
        })
    }
    $PreflightGrid.ItemsSource = $PreflightRows.ToArray()
    $BlockedPreflightCount = @($PreflightRows | Where-Object { $_.Status -eq "blocked" }).Count
    $WarningPreflightCount = @($PreflightRows | Where-Object { $_.Status -eq "warning" }).Count
    if ([string]$Result.preflight_status -eq "passed") {
        $PreflightStatus.Text = "Preflight superato: $($PreflightRows.Count) controlli autenticati; nessun requisito bloccante."
        $PreflightStatus.Foreground = Get-Brush "#16875D"
    } else {
        $PreflightStatus.Text = "Preflight non superato: $BlockedPreflightCount controlli bloccanti e $WarningPreflightCount avvisi. Correggere i punti indicati prima dell'importazione."
        $PreflightStatus.Foreground = Get-Brush "#C9342F"
        $ImportWorkspaceTabs.SelectedIndex = 1
    }

    $PlanRows = New-Object System.Collections.Generic.List[object]
    foreach ($Candidate in @($Result.candidates)) {
        if ($Candidate.action -eq "duplicate" -and $Candidate.duplicate_kind -eq "batch") {
            $ActionLabel = "Duplicato nel lotto"
        } elseif ($Candidate.action -eq "duplicate") {
            $ActionLabel = "Gia' nella destinazione"
        } elseif ($Candidate.action -eq "blocked") {
            $ActionLabel = "Presente altrove - bloccato"
        } else {
            $ActionLabel = "Da creare"
        }
        if ($Candidate.folder_action -eq "root") {
            $DestinationLabel = "Radice Passbolt"
        } elseif ($Candidate.folder_action -eq "reuse") {
            $DestinationLabel = "$($Candidate.folder_path) (esistente)"
        } elseif ($Candidate.folder_action -eq "missing") {
            $DestinationLabel = "Selezionare una cartella"
        } else {
            $DestinationLabel = "$($Candidate.folder_path) (nuova)"
        }
        if ([bool]$Candidate.shared) {
            $DestinationLabel += " [condivisa con $([int]$Candidate.share_recipient_count) destinatari]"
        }
        $PlanRows.Add([pscustomobject]@{
            CandidateId = [string]$Candidate.candidate_id
            Action = [string]$Candidate.action
            ActionLabel = $ActionLabel
            Destination = $DestinationLabel
            Title = [string]$Candidate.title
            Username = [string]$Candidate.username
            Uri = [string]$Candidate.uri
        })
    }
    $ImportPlanGrid.ItemsSource = $PlanRows.ToArray()
    $ImportMetricSelected.Text = [string]$script:ImportCandidates.Count
    $ImportMetricCreate.Text = [string]$Result.create_count
    $ImportMetricDuplicates.Text = [string]$Result.duplicate_count
    $ImportMetricExisting.Text = [string]$Result.create_folder_count
    $DisplayName = ("$($Result.user.first_name) $($Result.user.last_name)").Trim()
    if (-not $DisplayName) { $DisplayName = [string]$Result.user.username }
    $SelectedFolderLabel = if ($null -ne $DestinationFolder.SelectedItem) { [string]$DestinationFolder.SelectedItem.Content } else { "Radice personale Passbolt" }
    if ([string]$Result.destination_mode -eq "root") {
        $FolderIdentity = "radice"
    } elseif ([string]$Result.destination_mode -eq "direct_folder") {
        $FolderIdentity = "diretta: $SelectedFolderLabel"
    } elseif ([string]$Result.destination_mode -eq "client_mapping") {
        $FolderIdentity = "mappatura: $(@($Result.client_destination_mapping).Count)/$(@($Result.required_clients).Count) clienti"
    } elseif (-not [string]$Result.folder_format_selected) {
        $FolderIdentity = "nessuna nuova cartella"
    } else {
        $FolderIdentity = "contenitore: $SelectedFolderLabel; cartelle $($Result.folder_format_selected)"
    }
    $PermissionIdentity = if ([string]$Result.permission_mode -eq "custom") { "ACL personalizzata ($([int]$Result.permission_template_entry_count) destinatari espliciti)" } else { "ACL ereditata" }
    $ImportIdentity.Text = "Utente verificato: $DisplayName <$($Result.user.username)> | chiave $($Result.user_key_fingerprint) | $($Result.authentication) | risorse $($Result.resource_format_selected) | $FolderIdentity | $PermissionIdentity | tipo $($Result.resource_type.slug)"

    if ([bool]$ReadinessDiagnostic.CanImport -and [int]$Result.create_count -gt 0) {
        $ExpectedPhrase = "IMPORTA $([int]$Result.create_count)"
        $SharedFolderSummary = if ([int]$Result.create_shared_folder_count -gt 0) {
            $PermissionSource = if ([string]$Result.permission_mode -eq "custom") { "personalizzati" } else { "ereditati" }
            " Cartelle condivise da creare con permessi $($PermissionSource): $([int]$Result.create_shared_folder_count)."
        } else { "" }
        $ReconciledFolderSummary = if ([int]$Result.reconcile_shared_folder_count -gt 0) {
            " Cartelle personali vuote da riconciliare con i permessi del contenitore: $([int]$Result.reconcile_shared_folder_count)."
        } else { "" }
        $SharingSummary = if ([int]$Result.shared_create_count -gt 0) {
            " Risorse condivise: $([int]$Result.shared_create_count); copie cifrate complessive: $([int]$Result.encrypted_secret_copy_count)."
        } else { "" }
        $ImportPlanStatus.Text = "Preflight e dry-run completati. Nessuna modifica eseguita; cartelle nuove: $($Result.create_folder_count), da riconciliare: $($Result.reconcile_shared_folder_count), cartelle riutilizzate: $($Result.reuse_folder_count).$SharedFolderSummary$ReconciledFolderSummary$SharingSummary Le cartelle Passbolt sono caricate: se cambi la destinazione, ripeti il preflight."
        $ConfirmationHint.Text = "Sessione sicura attiva. Digita: $ExpectedPhrase"
        $ImportConfirmation.IsEnabled = $true
        Add-Activity "Preflight superato e dry-run completato: $($Result.create_count) risorse e $($Result.create_folder_count) cartelle da creare, $($Result.reconcile_shared_folder_count) cartelle da riconciliare, incluse $($Result.create_shared_folder_count) nuove condivise; $($Result.duplicate_count) duplicati nella destinazione."
    } elseif ([bool]$ReadinessDiagnostic.CanImport) {
        $ImportPlanStatus.Text = "Dry-run completato: tutti i candidati selezionati risultano gia' presenti."
        $ConfirmationHint.Text = "Nessuna nuova risorsa da creare."
        Add-Activity "Dry-run completato: nessuna nuova risorsa; $($Result.duplicate_count) duplicati esatti."
    } else {
        $ImportPlanStatus.Text = [string]$ReadinessDiagnostic.Cause
        $ConfirmationHint.Text = [string]$ReadinessDiagnostic.Hint
        Add-Activity "Dry-run completato; scrittura bloccata ($([string]$ReadinessDiagnostic.ActivityCode))."
    }
}

function Complete-ImportReadinessFailure([string]$FailureMessage, [bool]$CloseSession) {
    if ($CloseSession -or -not (Test-ImportSessionActive)) { Stop-ImportSession "" $false }
    Reset-ImportPlan "Dry-run non riuscito. Nessuna modifica e' stata eseguita."
    Add-Activity "Dry-run non riuscito: $FailureMessage"
    Update-ImportSessionState
    [System.Windows.MessageBox]::Show($FailureMessage, "Dry-run non riuscito", "OK", "Error") | Out-Null
}

function Resolve-RequestedResourceFormat([AllowNull()][object]$SelectedItem) {
    if ($null -eq $SelectedItem) { return "" }
    return [string]$SelectedItem.Tag
}

function Invoke-ImportReadiness {
    if ($script:ImportRecoveryRequired) {
        Show-Phase04Workspace "recovery" -SkipRefresh
        [System.Windows.MessageBox]::Show(
            "Una precedente importazione richiede verifica. Completare o gestire il journal nel recupero guidato prima di preparare un nuovo dry-run.",
            "Recupero obbligatorio",
            "OK",
            "Warning"
        ) | Out-Null
        return
    }
    if (-not $script:ConnectionVerified -or -not $script:VerifiedUrl -or -not $script:VerifiedFingerprint) {
        [System.Windows.MessageBox]::Show("Verificare il server e confermare la fingerprint nella parte superiore della fase 04.", "Connessione non verificata", "OK", "Warning") | Out-Null
        return
    }
    if ($script:ImportCandidates.Count -lt 1) {
        [System.Windows.MessageBox]::Show("Tornare alla revisione e selezionare almeno un candidato pronto.", "Nessun candidato", "OK", "Warning") | Out-Null
        return
    }
    if (-not (Test-ImportSessionActive) -or $script:ImportSessionRoot -ne $script:InventoryFolder) {
        [System.Windows.MessageBox]::Show("Avviare prima la sessione sicura con chiave privata, passphrase e MFA.", "Sessione non attiva", "OK", "Warning") | Out-Null
        return
    }

    Reset-ImportOperationalViews
    Reset-ImportPlan "Preflight autenticato e dry-run nella sessione attiva in corso..."
    $RequestedResourceFormat = Resolve-RequestedResourceFormat $ResourceFormat.SelectedItem
    $RequestedFolderFormat = "v4"
    $RequestedDestinationMode = [string]$DestinationMode.SelectedItem.Tag
    if ($RequestedDestinationMode -notin @("client_folders", "client_mapping", "direct_folder", "root")) { $RequestedDestinationMode = "client_folders" }
    $RequestedDestinationFolderId = if ($RequestedDestinationMode -eq "client_mapping") { "" } else { Get-SelectedDestinationFolderId }
    $RequestedClientDestinationMapping = if ($RequestedDestinationMode -eq "client_mapping") { @(Get-ClientDestinationMappingPayload) } else { @() }
    try {
        $ReadinessSourceFilePasswords = @(Get-ImportSourceFilePasswordPayload $script:ImportCandidates)
        $ReadinessRequest = [pscustomobject][ordered]@{
            command = "session-readiness"
            session_id = $script:ImportSessionId
            resource_format = $RequestedResourceFormat
            destination_mode = $RequestedDestinationMode
            folder_format = $RequestedFolderFormat
            destination_folder_id = $RequestedDestinationFolderId
            client_destination_mapping = $RequestedClientDestinationMapping
            permission_mode = $script:PermissionMode
            permission_template = @(Get-PermissionTemplatePayload)
            candidates = $script:ImportCandidates
            source_file_passwords = $ReadinessSourceFilePasswords
        }
        Add-Activity "Avvio preflight e dry-run nella sessione GPGAuth attiva (risorse $RequestedResourceFormat, cartelle $RequestedFolderFormat)."
        $OperationParameters = @{
            Name = "Preflight e dry-run import"
            Category = "verify"
            WorkKind = "ImportSessionJson"
            Payload = New-ImportSessionOperationPayload $ReadinessRequest
            OnSuccess = {
                param($Envelope, $Operation)
                if (-not [bool]$Envelope.ok) {
                    Complete-ImportReadinessFailure (Get-SecureErrorMessage $Envelope) (Test-TerminalImportSessionError $Envelope)
                    return
                }
                try { Set-ImportReadinessResult $Envelope.result }
                catch {
                    Complete-ImportReadinessFailure ([string]$_.Exception.Message) $true
                    return
                }
                Update-ImportSessionState
            }
            OnFailure = {
                param($FailureMessage, $Operation)
                Complete-ImportReadinessFailure $FailureMessage $true
            }
        }
        [void](Start-UiOperation @OperationParameters)
    } catch {
        Clear-OperationalSensitivePayload ([pscustomobject]@{ InputObject = $ReadinessRequest })
        Complete-ImportReadinessFailure ([string]$_.Exception.Message) $false
    }
}
function Complete-ConfirmedImportFailure(
    [string]$FailureMessage,
    [bool]$CloseSession
) {
    Set-ImportDashboardFailure $FailureMessage
    $script:ImportRecoveryRequired = $true
    if ($CloseSession -or -not (Test-ImportSessionActive)) { Stop-ImportSession "" $false }
    Reset-ImportPlan "Importazione interrotta. Aprire la scheda di recupero e verificare il lotto autenticato prima di riprovare."
    Add-Activity "Importazione non completata: $FailureMessage"
    Update-ImportSessionState
    [System.Windows.MessageBox]::Show($FailureMessage, "Importazione non completata - v0.29.0-beta.1", "OK", "Error") | Out-Null
    Show-Phase04Workspace "recovery" -SkipRefresh
    Refresh-RecoveryBatches -Quiet
}

function Set-ConfirmedImportResult([object]$Result, [string[]]$CreateCandidateIds, [object]$PreflightReceiptEvidence) {
    $VerificationRows = New-Object System.Collections.Generic.List[object]
    $TitlesByCandidate = @{}
    foreach ($Candidate in @($script:ImportCandidates)) {
        $TitlesByCandidate[[string]$Candidate.candidate_id] = [string]$Candidate.title
    }
    foreach ($Verification in @($Result.verification_results)) {
        $VerificationRows.Add([pscustomobject]@{
            CandidateId = [string]$Verification.candidate_id
            Title = if ($TitlesByCandidate.ContainsKey([string]$Verification.candidate_id)) { [string]$TitlesByCandidate[[string]$Verification.candidate_id] } else { "Risorsa creata" }
            MetadataLabel = if ([bool]$Verification.metadata_match) { "Verificati" } else { "Non conformi" }
            ContentLabel = if ([bool]$Verification.content_match) { "Verificato" } else { "Non conforme" }
            DestinationLabel = if ([bool]$Verification.destination_match) { "Corretta" } else { "Non conforme" }
            AclLabel = if ([bool]$Verification.acl_match) { "Corretta" } else { "Non conforme" }
            StatusLabel = if ([string]$Verification.status -eq "verified") { "Confermata" } else { "Da verificare" }
        })
    }
    $VerificationGrid.ItemsSource = $VerificationRows.ToArray()
    $VerificationStatus.Text = "Verifica automatica completata: $([int]$Result.verified_resource_count) risorse rilette; metadati, contenuto cifrato, cartella e ACL coincidono con il piano. Nessuna password o impronta del contenuto e' stata conservata."
    $VerificationStatus.Foreground = Get-Brush "#16875D"
    $ImportWorkspaceTabs.SelectedIndex = 2
    $script:ImportCompleted = $true
    $script:MigrationReceiptEvidence = $null
    if (
        $null -ne $PreflightReceiptEvidence -and
        [bool]$Result.complete -and
        [string]$Result.verification_status -eq "verified" -and
        [int]$Result.verification_failed_count -eq 0 -and
        [string]$Result.reconciliation_status -eq "complete" -and
        -not [string]::IsNullOrWhiteSpace([string]$Result.reconciliation_batch_id)
    ) {
        $script:MigrationReceiptEvidence = New-MigrationReceiptEvidence $Result $PreflightReceiptEvidence
        $ExportMigrationReceiptButton.IsEnabled = $true
    } else {
        $ExportMigrationReceiptButton.IsEnabled = $false
        Add-Activity "Ricevuta finale non disponibile: la risposta non attesta insieme verifica completa e chiusura del journal."
    }
    $script:ImportPlan = $null
    foreach ($CandidateId in $CreateCandidateIds) {
        if ($script:ImportSecretOverrides.ContainsKey($CandidateId)) { $script:ImportSecretOverrides.Remove($CandidateId) }
        foreach ($ReviewRow in @($script:AllReviewRows | Where-Object { [string]$_.CandidateId -eq $CandidateId })) {
            $ReviewRow.SecretValue = ""
            $ReviewRow.SecretCachedFromSource = $false
            $ReviewRow.PasswordOverridden = $false
            Update-ReviewRowState $ReviewRow
        }
    }
    Update-ReviewMetrics
    $ImportConfirmation.Text = ""
    $ImportConfirmation.IsEnabled = $false
    $ConfirmationHint.Text = "Importazione completata e verificata. La sessione resta attiva per il prossimo lotto."
    $ImportPlanStatus.Text = "Importazione completata e verificata: $($Result.created_folder_count) cartelle create, incluse $($Result.shared_created_folder_count) condivise, $($Result.reconciled_shared_folder_count) cartelle riconciliate e $($Result.created_count) risorse create e rilette, incluse $($Result.shared_created_count) condivise; $($Result.skipped_duplicate_count) duplicati saltati."
    foreach ($Row in @($ImportPlanGrid.ItemsSource)) {
        if ($Row.Action -eq "create") { $Row.ActionLabel = "Creata" }
    }
    $ImportPlanGrid.Items.Refresh()
    Add-Activity "Importazione completata e verificata: $($Result.created_folder_count) cartelle create, incluse $($Result.shared_created_folder_count) condivise, $($Result.reconciled_shared_folder_count) cartelle riconciliate e $($Result.verified_resource_count) risorse rilette con esito conforme; $($Result.skipped_duplicate_count) duplicati saltati."
    if (-not [string]::IsNullOrWhiteSpace([string]$Result.reconciliation_batch_id)) {
        Add-Activity "Registro locale del lotto $([string]$Result.reconciliation_batch_id) completato."
    }
    Update-ImportSessionState
    $Summary = @(
        "Importazione completata e verificata correttamente.",
        "",
        "Cartelle create: $($Result.created_folder_count)",
        "Cartelle condivise create: $($Result.shared_created_folder_count)",
        "Cartelle personali riconciliate: $($Result.reconciled_shared_folder_count)",
        "Cartelle riutilizzate: $($Result.reused_folder_count)",
        "Risorse create: $($Result.created_count)",
        "Risorse rilette e conformi: $($Result.verified_resource_count)",
        "Risorse condivise: $($Result.shared_created_count)",
        "Copie cifrate complessive: $($Result.encrypted_secret_copy_count)",
        "Duplicati saltati: $($Result.skipped_duplicate_count)"
    ) -join [Environment]::NewLine
    [System.Windows.MessageBox]::Show($Summary, "Importazione completata e verificata", "OK", "Information") | Out-Null
    Refresh-RecoveryBatches -Quiet
}

function Get-ConfirmedImportFailureMessage([object]$Envelope) {
    $CreatedBeforeFailure = 0
    if ($null -ne $Envelope.error.details -and $null -ne $Envelope.error.details.created) {
        $CreatedBeforeFailure = @($Envelope.error.details.created).Count
    }
    $CreatedFoldersBeforeFailure = 0
    if ($null -ne $Envelope.error.details -and $null -ne $Envelope.error.details.created_folders) {
        $CreatedFoldersBeforeFailure = @($Envelope.error.details.created_folders).Count
    }
    $Message = Get-SecureErrorMessage $Envelope
    if ($null -ne $Envelope.error.details -and -not [string]::IsNullOrWhiteSpace([string]$Envelope.error.details.reconciliation_batch_id)) {
        $Message += [Environment]::NewLine + [Environment]::NewLine + "Registro locale del lotto: $([string]$Envelope.error.details.reconciliation_batch_id). Lo stato richiede una verifica autenticata prima di qualunque nuovo tentativo. Apri la scheda 'Recupero import interrotto' della fase 04 e associa la cartella sorgente corrente."
    }
    if ($CreatedBeforeFailure -gt 0 -or $CreatedFoldersBeforeFailure -gt 0) {
        $Message += [Environment]::NewLine + [Environment]::NewLine + "Attenzione: $CreatedFoldersBeforeFailure cartelle e $CreatedBeforeFailure risorse risultano create prima dell'errore. Usare il recupero guidato per riverificare lo stato; non verranno eliminate automaticamente."
    }
    if ($null -ne $Envelope.error.details -and [bool]$Envelope.error.details.folder_reconciliation_failed) {
        $Message += [Environment]::NewLine + [Environment]::NewLine + "La cartella personale $($Envelope.error.details.existing_personal_folder_id) non e' stata riconciliata con i permessi del contenitore. Nessuna risorsa del cliente e' stata inserita al suo interno. Usare il recupero guidato per verificare lo stato corrente."
    } elseif ($null -ne $Envelope.error.details -and [bool]$Envelope.error.details.folder_sharing_failed) {
        $Message += [Environment]::NewLine + [Environment]::NewLine + "La cartella $($Envelope.error.details.created_unshared_folder_id) e' stata creata ma i permessi ereditati non sono stati applicati. Al momento resta personale; nessuna risorsa del cliente e' stata inserita al suo interno. Usare il recupero guidato per riconciliare lo stato."
    } elseif ($null -ne $Envelope.error.details -and [bool]$Envelope.error.details.sharing_failed) {
        $Message += [Environment]::NewLine + [Environment]::NewLine + "La risorsa $($Envelope.error.details.created_unshared_resource_id) e' stata creata ma la condivisione non e' stata applicata. Al momento resta personale e deve essere riconciliata dal recupero guidato prima di continuare."
    }
    return $Message
}

function Invoke-ConfirmedImport {
    Update-ExecuteImportState
    if (-not $ExecuteImportButton.IsEnabled) { return }
    if (-not (Test-ImportSessionActive)) {
        [System.Windows.MessageBox]::Show("La sessione sicura non e' piu attiva. Avviarne una nuova e ripetere il dry-run.", "Sessione scaduta", "OK", "Warning") | Out-Null
        return
    }
    $CreateCount = [int]$script:ImportPlan.create_count
    $DuplicateCount = [int]$script:ImportPlan.duplicate_count
    $CreateFolderCount = [int]$script:ImportPlan.create_folder_count
    $CreateSharedFolderCount = [int]$script:ImportPlan.create_shared_folder_count
    $ReconcileSharedFolderCount = [int]$script:ImportPlan.reconcile_shared_folder_count
    $ReuseFolderCount = [int]$script:ImportPlan.reuse_folder_count
    $SharedCreateCount = [int]$script:ImportPlan.shared_create_count
    $EncryptedSecretCopyCount = [int]$script:ImportPlan.encrypted_secret_copy_count
    $SharingConfirmation = if ($SharedCreateCount -gt 0) {
        $PermissionAction = if ([string]$script:ImportPlan.permission_mode -eq "custom") { "riceveranno la ACL personalizzata verificata" } else { "erediteranno i permessi delle cartelle condivise" }
        " Di queste, $SharedCreateCount risorse $PermissionAction; saranno prodotte $EncryptedSecretCopyCount copie cifrate complessive dei segreti. Ogni condivisione verra' prima simulata da Passbolt."
    } else { "" }
    $FolderSharingConfirmation = if ($CreateSharedFolderCount -gt 0) {
        $FolderPermissionAction = if ([string]$script:ImportPlan.permission_mode -eq "custom") { "la ACL personalizzata verificata" } else { "la maschera completa del contenitore" }
        " $CreateSharedFolderCount nuove cartelle saranno create e riceveranno $FolderPermissionAction prima di creare le relative risorse."
    } else { "" }
    $FolderReconciliationConfirmation = if ($ReconcileSharedFolderCount -gt 0) {
        " $ReconcileSharedFolderCount cartelle personali gia' esistenti, verificate come vuote e di proprieta' dell'utente autenticato, riceveranno la maschera di permessi del contenitore prima della creazione delle risorse."
    } else { "" }
    $Decision = [System.Windows.MessageBox]::Show(
        "Passbolt creera' $CreateFolderCount cartelle e $CreateCount risorse, riconciliera' $ReconcileSharedFolderCount cartelle personali, riutilizzera' $ReuseFolderCount cartelle e saltera' $DuplicateCount duplicati nella destinazione.$FolderSharingConfirmation$FolderReconciliationConfirmation$SharingConfirmation Le operazioni sono sequenziali: in caso di interruzione verra' mostrato quante sono riuscite. Continuare?",
        "Conferma scrittura su Passbolt",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($Decision -ne [System.Windows.MessageBoxResult]::Yes) { return }

    $CreateCandidateIds = @($script:ImportPlan.candidates | Where-Object { $_.action -eq "create" } | ForEach-Object { [string]$_.candidate_id })
    $SecretOverrides = New-Object System.Collections.Generic.List[object]
    foreach ($CandidateId in $CreateCandidateIds) {
        $Candidate = @($script:ImportCandidates | Where-Object { [string]$_.candidate_id -eq $CandidateId }) | Select-Object -First 1
        if ($null -ne $Candidate -and [bool]$Candidate.password_overridden) {
            if (-not $script:ImportSecretOverrides.ContainsKey($CandidateId) -or -not [string]$script:ImportSecretOverrides[$CandidateId]) {
                [System.Windows.MessageBox]::Show("Una password modificata non e' piu disponibile in memoria. Tornare alla revisione e modificarla nuovamente.", "Password non disponibile", "OK", "Error") | Out-Null
                return
            }
            $SecretOverrides.Add([pscustomobject][ordered]@{ candidate_id = $CandidateId; password = [string]$script:ImportSecretOverrides[$CandidateId] })
        }
    }
    $CreateCandidates = @($script:ImportCandidates | Where-Object { [string]$_.candidate_id -in $CreateCandidateIds })
    try {
        $WriteSourceFilePasswords = @(Get-ImportSourceFilePasswordPayload $CreateCandidates)
        $ExecuteRequest = [pscustomobject][ordered]@{
            command = "session-import"
            session_id = $script:ImportSessionId
            resource_format = [string]$script:ImportPlan.resource_format_requested
            destination_mode = [string]$script:ImportPlan.destination_mode
            folder_format = [string]$script:ImportPlan.folder_format_requested
            destination_folder_id = [string]$script:ImportPlan.destination_folder_id
            client_destination_mapping = @($script:ImportPlan.client_destination_mapping)
            permission_mode = [string]$script:ImportPlan.permission_mode
            permission_template = @(Get-PermissionTemplatePayload)
            candidates = $script:ImportCandidates
            create_candidate_ids = $CreateCandidateIds
            secret_overrides = $SecretOverrides.ToArray()
            source_file_passwords = $WriteSourceFilePasswords
            plan_digest = [string]$script:ImportPlan.plan_digest
            confirmation = "IMPORTA $CreateCount"
        }
        Add-Activity "Avvio importazione confermata di $CreateCount risorse."
        Initialize-ImportDashboard $CreateCount $DuplicateCount ($CreateFolderCount + $ReconcileSharedFolderCount)
        $OperationParameters = @{
            Name = "Importazione Passbolt"
            Category = "write"
            WorkKind = "ImportSessionJson"
            Payload = New-ImportSessionOperationPayload $ExecuteRequest 3600000
            Context = [pscustomobject]@{
                CreateCandidateIds = $CreateCandidateIds
                PreflightReceiptEvidence = $script:PreflightReceiptEvidence
            }
            OnProgress = {
                param($ProgressEnvelope, $Operation)
                Update-ImportDashboardProgress $ProgressEnvelope
            }
            OnSuccess = {
                param($Envelope, $Operation)
                if (-not [bool]$Envelope.ok) {
                    Complete-ConfirmedImportFailure (Get-ConfirmedImportFailureMessage $Envelope) (Test-TerminalImportSessionError $Envelope)
                    return
                }
                try { Set-ConfirmedImportResult $Envelope.result @($Operation.Context.CreateCandidateIds) $Operation.Context.PreflightReceiptEvidence }
                catch { Complete-ConfirmedImportFailure ([string]$_.Exception.Message) $true }
            }
            OnFailure = {
                param($FailureMessage, $Operation)
                Complete-ConfirmedImportFailure $FailureMessage $true
            }
        }
        [void](Start-UiOperation @OperationParameters)
    } catch {
        Clear-OperationalSensitivePayload ([pscustomobject]@{ InputObject = $ExecuteRequest })
        foreach ($Entry in $SecretOverrides) { $Entry.password = $null }
        Complete-ConfirmedImportFailure ([string]$_.Exception.Message) $false
    }
}
function Complete-RecoveryReadinessFailure([string]$FailureMessage, [bool]$CloseSession) {
    if ($CloseSession -or -not (Test-ImportSessionActive)) { Stop-ImportSession "" $false }
    Reset-RecoveryPlan "Verifica del lotto non riuscita. Nessuna azione di recupero e' stata applicata."
    Add-Activity "Verifica del lotto non riuscita: $FailureMessage"
    Update-ImportSessionState
    [System.Windows.MessageBox]::Show($FailureMessage, "Verifica recupero non riuscita", "OK", "Error") | Out-Null
}

function Invoke-RecoveryReadiness {
    $Selected = $RecoveryBatchesGrid.SelectedItem
    if ($null -eq $Selected -or [string]$Selected.Status -ne "recovery_required") { return }
    if ($null -eq $script:RecoveryBatchDetails -or [string]$script:RecoveryBatchDetails.batch_id -ne [string]$Selected.BatchId -or $script:RecoveryCandidates.Count -lt 1) {
        [System.Windows.MessageBox]::Show("Associare prima il lotto a tutti i candidati riletti dalla cartella sorgente corrente.", "Sorgenti non associati", "OK", "Warning") | Out-Null
        return
    }
    if (-not (Test-ImportSessionActive) -or $script:ImportSessionRoot -ne $script:InventoryFolder) {
        [System.Windows.MessageBox]::Show("Avviare prima la sessione sicura con chiave privata, passphrase e MFA.", "Sessione non attiva", "OK", "Warning") | Out-Null
        return
    }

    if ($null -ne $script:ImportPlan) {
        Reset-ImportPlan "Il piano della nuova importazione e' stato invalidato per verificare un lotto interrotto."
    }
    Reset-RecoveryPlan "Verifica autenticata di identita', sorgenti, destinazione e stato remoto in corso..."
    $BatchId = [string]$Selected.BatchId
    try {
        $SourceFilePasswords = @(Get-CandidateSourceFilePasswordPayload $script:RecoveryCandidates $script:RecoverySourceFilePasswords)
        $ReadinessRequest = [pscustomobject][ordered]@{
            command = "session-recovery-readiness"
            session_id = $script:ImportSessionId
            reconciliation_batch_id = $BatchId
            permission_mode = $script:PermissionMode
            permission_template = @(Get-PermissionTemplatePayload)
            candidates = $script:RecoveryCandidates
            source_file_passwords = $SourceFilePasswords
        }
        Add-Activity "Avvio verifica autenticata del lotto $BatchId."
        $OperationParameters = @{
            Name = "Verifica recupero import"
            Category = "recover"
            WorkKind = "ImportSessionJson"
            Payload = New-ImportSessionOperationPayload $ReadinessRequest
            Context = [pscustomobject]@{ BatchId = $BatchId }
            OnSuccess = {
                param($Envelope, $Operation)
                if (-not [bool]$Envelope.ok) {
                    Complete-RecoveryReadinessFailure (Get-SecureErrorMessage $Envelope) (Test-TerminalImportSessionError $Envelope)
                    return
                }
                $Result = $Envelope.result
                $ExpectedBatchId = [string]$Operation.Context.BatchId
                if (
                    [string]$Result.reconciliation_batch_id -ne $ExpectedBatchId -or
                    -not [bool]$Result.can_recover -or
                    [bool]$Result.destructive_actions_planned -or
                    [int]$Result.conflict_count -ne 0 -or
                    [string]$Result.confirmation_required -ne "RECUPERA $([int]$Result.retry_action_count)" -or
                    -not [string]$Result.recovery_id -or
                    -not [string]$Result.recovery_plan_digest
                ) {
                    Complete-RecoveryReadinessFailure "La verifica del recupero ha restituito un piano incoerente o non sicuro." $true
                    return
                }
                $script:RecoveryPlan = $Result
                $RecoveryMetricVerified.Text = [string]$Result.verified_operation_count
                $RecoveryMetricRemoteSuccess.Text = [string]$Result.remote_success_count
                $RecoveryMetricNotApplied.Text = [string]$Result.not_applied_count
                $RecoveryMetricConflicts.Text = [string]$Result.conflict_count
                $RecoverySafetyStatus.Text = "Piano verificato: nessuna azione distruttiva. Le operazioni gia' riuscite saranno riconciliate; saranno ripetute soltanto $([int]$Result.retry_action_count) azioni dimostrate come non applicate."
                $RecoverySafetyStatus.Foreground = Get-Brush "#248A3D"
                $RecoveryStatus.Text = "Verifica completata: $([int]$Result.remote_success_count) operazioni gia' riuscite, $([int]$Result.not_applied_count) non applicate, $([int]$Result.conflict_count) conflitti. Il lotto e' bloccato a questo piano fino al recupero o alla chiusura della sessione."
                $RecoveryConfirmationHint.Text = "Digita: $([string]$Result.confirmation_required)"
                Add-Activity "Lotto $ExpectedBatchId verificato: $([int]$Result.remote_success_count) esiti remoti confermati, $([int]$Result.retry_action_count) azioni idempotenti da applicare, nessun conflitto."
                Update-ImportSessionState
            }
            OnFailure = {
                param($FailureMessage, $Operation)
                Complete-RecoveryReadinessFailure $FailureMessage $true
            }
        }
        [void](Start-UiOperation @OperationParameters)
    } catch {
        Clear-OperationalSensitivePayload ([pscustomobject]@{ InputObject = $ReadinessRequest })
        Complete-RecoveryReadinessFailure ([string]$_.Exception.Message) $false
    }
}
function Complete-ConfirmedRecoveryFailure([string]$FailureMessage, [bool]$CloseSession) {
    $script:ImportRecoveryRequired = $true
    if ($CloseSession -or -not (Test-ImportSessionActive)) { Stop-ImportSession "" $false }
    Reset-RecoveryPlan "Recupero interrotto. Aggiornare il lotto e ripetere la verifica autenticata; nessuna operazione distruttiva verra' tentata."
    Add-Activity "Recupero del lotto non completato: $FailureMessage"
    Update-ImportSessionState
    [System.Windows.MessageBox]::Show($FailureMessage, "Recupero non completato", "OK", "Error") | Out-Null
    Refresh-RecoveryBatches -Quiet
}

function Invoke-ConfirmedRecovery {
    Update-RecoveryActionState
    if (-not $ExecuteRecoveryButton.IsEnabled -or $null -eq $script:RecoveryPlan) { return }
    if (-not (Test-ImportSessionActive)) {
        [System.Windows.MessageBox]::Show("La sessione sicura non e' piu attiva. Avviarne una nuova e ripetere la verifica del lotto.", "Sessione scaduta", "OK", "Warning") | Out-Null
        return
    }

    $Plan = $script:RecoveryPlan
    $RetryCount = [int]$Plan.retry_action_count
    $RemoteSuccessCount = [int]$Plan.remote_success_count
    $Decision = [System.Windows.MessageBox]::Show(
        "Il recupero riconciliera' $RemoteSuccessCount operazioni gia' riuscite e applichera' soltanto $RetryCount azioni verificate come non eseguite. Non sono previste cancellazioni, spostamenti o sovrascritture. Continuare?",
        "Conferma recupero idempotente",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($Decision -ne [System.Windows.MessageBoxResult]::Yes) { return }

    $ResourceCandidateIds = @($Plan.resource_candidate_ids | ForEach-Object { [string]$_ })
    $SecretOverrides = New-Object System.Collections.Generic.List[object]
    foreach ($CandidateId in $ResourceCandidateIds) {
        $Candidate = @($script:RecoveryCandidates | Where-Object { [string]$_.candidate_id -eq $CandidateId }) | Select-Object -First 1
        if ($null -ne $Candidate -and [bool]$Candidate.password_overridden) {
            if (-not $script:RecoverySecretOverrides.ContainsKey($CandidateId) -or -not [string]$script:RecoverySecretOverrides[$CandidateId]) {
                [System.Windows.MessageBox]::Show("Una password modificata non e' piu disponibile in memoria. Tornare alla revisione, riapplicare la modifica e riverificare il lotto.", "Password non disponibile", "OK", "Error") | Out-Null
                return
            }
            $SecretOverrides.Add([pscustomobject][ordered]@{ candidate_id = $CandidateId; password = [string]$script:RecoverySecretOverrides[$CandidateId] })
        }
    }

    $BatchId = [string]$Plan.reconciliation_batch_id
    try {
        $SourceFilePasswords = @(Get-CandidateSourceFilePasswordPayload $script:RecoveryCandidates $script:RecoverySourceFilePasswords)
        $ExecuteRequest = [pscustomobject][ordered]@{
            command = "session-recovery-import"
            session_id = $script:ImportSessionId
            reconciliation_batch_id = $BatchId
            recovery_id = [string]$Plan.recovery_id
            recovery_plan_digest = [string]$Plan.recovery_plan_digest
            resource_candidate_ids = $ResourceCandidateIds
            permission_mode = $script:PermissionMode
            permission_template = @(Get-PermissionTemplatePayload)
            candidates = $script:RecoveryCandidates
            secret_overrides = $SecretOverrides.ToArray()
            source_file_passwords = $SourceFilePasswords
            confirmation = [string]$Plan.confirmation_required
        }
        Add-Activity "Avvio recupero confermato del lotto $BatchId con $RetryCount azioni idempotenti."
        $OperationParameters = @{
            Name = "Recupero import interrotto"
            Category = "recover"
            WorkKind = "ImportSessionJson"
            Payload = New-ImportSessionOperationPayload $ExecuteRequest
            Context = [pscustomobject]@{ BatchId = $BatchId }
            OnSuccess = {
                param($Envelope, $Operation)
                if (-not [bool]$Envelope.ok) {
                    Complete-ConfirmedRecoveryFailure (Get-SecureErrorMessage $Envelope) (Test-TerminalImportSessionError $Envelope)
                    return
                }
                $Result = $Envelope.result
                if (-not [bool]$Result.complete -or [bool]$Result.destructive_actions_performed) {
                    Complete-ConfirmedRecoveryFailure "Il recupero non ha restituito una chiusura sicura e verificabile del lotto." $true
                    return
                }
                $script:RecoveryPlan = $null
                $RemainingRecoveryBatches = @($script:RecoveryBatches | Where-Object {
                    [string]$_.BatchId -ne [string]$Operation.Context.BatchId -and [string]$_.Status -ne "complete"
                })
                $script:ImportRecoveryRequired = $RemainingRecoveryBatches.Count -gt 0
                $RecoveryConfirmation.Text = ""
                $RecoveryConfirmation.IsEnabled = $false
                $RecoveryStatus.Text = "Recupero completato e journal chiuso."
                $RecoveryConfirmationHint.Text = "Il lotto completato puo' essere archiviato."
                Add-Activity "Recupero del lotto $([string]$Operation.Context.BatchId) completato: $([int]$Result.created_folder_count) cartelle create, $([int]$Result.reconciled_folder_count) riconciliate, $([int]$Result.created_count) risorse create e $([int]$Result.repaired_resource_count) condivisioni riparate."
                Update-ImportSessionState
                $Summary = @(
                    "Recupero completato correttamente.",
                    "",
                    "Cartelle create: $([int]$Result.created_folder_count)",
                    "Cartelle riconciliate: $([int]$Result.reconciled_folder_count)",
                    "Risorse create: $([int]$Result.created_count)",
                    "Condivisioni riparate: $([int]$Result.repaired_resource_count)",
                    "Operazioni remote gia' riuscite: $([int]$Result.remote_success_count)",
                    "Azioni distruttive: nessuna",
                    "",
                    "Archiviare ora il journal completato?"
                ) -join [Environment]::NewLine
                $ArchiveDecision = [System.Windows.MessageBox]::Show($Summary, "Recupero completato", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Information)
                if ($ArchiveDecision -eq [System.Windows.MessageBoxResult]::Yes -and $null -ne $RecoveryBatchesGrid.SelectedItem) {
                    $RecoveryBatchesGrid.SelectedItem.Status = "complete"
                    $RecoveryBatchesGrid.SelectedItem.StatusLabel = Get-RecoveryStatusLabel "complete"
                    Invoke-ArchiveRecoveryBatch -AlreadyConfirmed
                } else {
                    Refresh-RecoveryBatches -Quiet
                }
            }
            OnFailure = {
                param($FailureMessage, $Operation)
                Complete-ConfirmedRecoveryFailure $FailureMessage $true
            }
        }
        [void](Start-UiOperation @OperationParameters)
    } catch {
        Clear-OperationalSensitivePayload ([pscustomobject]@{ InputObject = $ExecuteRequest })
        foreach ($Entry in $SecretOverrides) { $Entry.password = $null }
        Complete-ConfirmedRecoveryFailure ([string]$_.Exception.Message) $false
    }
}
function Test-SelectedFolder {
    $Folder = $ClientFolder.Text.Trim()
    return [bool]($Folder -and (Test-Path -LiteralPath $Folder -PathType Container))
}

function Update-ConfigurationState {
    $FolderIsValid = Test-SelectedFolder
    if ($FolderIsValid) {
        $FolderDot.Fill = Get-Brush "#248A3D"
        $FolderStatus.Text = "Cartella valida e accessibile"
        $FolderStatus.Foreground = Get-Brush "#248A3D"
    } elseif ($ClientFolder.Text.Trim()) {
        $FolderDot.Fill = Get-Brush "#D70015"
        $FolderStatus.Text = "Cartella non trovata o non accessibile"
        $FolderStatus.Foreground = Get-Brush "#D70015"
    } else {
        $FolderDot.Fill = Get-Brush "#AEAEB2"
        $FolderStatus.Text = "Nessuna cartella selezionata"
        $FolderStatus.Foreground = Get-Brush "#6E6E73"
    }

    $CanContinue = $FolderIsValid
    $ContinueButton.IsEnabled = $CanContinue
    $StepInventory.IsEnabled = $CanContinue
    $InventoryCanBeSaved = $CanContinue -and [bool]$PlannedPassboltUrl.Text.Trim() -and $null -ne $script:InventoryResult -and $script:InventoryFolder -eq $ClientFolder.Text.Trim()
    $SaveInventoryProjectButton.IsEnabled = $InventoryCanBeSaved
    $SaveReviewProjectButton.IsEnabled = $InventoryCanBeSaved -and $null -ne $script:ReviewResult
    if ($CanContinue) {
        $StepInventoryNumber.Foreground = Get-Brush "#007AFF"
        $StepInventoryText.Foreground = Get-Brush "#3A3A3C"
    } elseif ($script:CurrentPage -ne "Inventory") {
        $StepInventoryNumber.Foreground = Get-Brush "#8E8E93"
        $StepInventoryText.Foreground = Get-Brush "#8E8E93"
    }
}

function Show-Page([ValidateSet("Configuration", "Inventory", "Review", "Import")][string]$Page) {
    if ($Page -ne "Review" -and $script:ReviewPasswordsVisible) {
        Set-ReviewPasswordsVisible $false
    }
    $script:CurrentPage = $Page
    $ConfigurationPage.Visibility = "Collapsed"
    $InventoryPage.Visibility = "Collapsed"
    $ReviewPage.Visibility = "Collapsed"
    $ImportPage.Visibility = "Collapsed"
    foreach ($Step in @($StepConfiguration, $StepInventory, $StepReview, $StepImport)) {
        $Step.Background = Get-Brush "#F2F2F7"
    }
    $StepConfigurationText.FontWeight = "Normal"
    $StepInventoryText.FontWeight = "Normal"
    $StepReviewText.FontWeight = "Normal"
    $StepImportText.FontWeight = "Normal"

    if ($Page -eq "Configuration") {
        $ConfigurationPage.Visibility = "Visible"
        $StepConfiguration.Background = Get-Brush "#FFFFFF"
        $StepConfigurationNumber.Foreground = Get-Brush "#007AFF"
        $StepConfigurationText.Foreground = Get-Brush "#1D1D1F"
        $StepConfigurationText.FontWeight = "SemiBold"
        $SafeModeText.Text = "Configurazione e inventario non aprono il contenuto dei documenti."
    } elseif ($Page -eq "Inventory") {
        $InventoryPage.Visibility = "Visible"
        $StepConfigurationNumber.Foreground = Get-Brush "#007AFF"
        $StepConfigurationText.Foreground = Get-Brush "#3A3A3C"
        $StepInventory.Background = Get-Brush "#FFFFFF"
        $StepInventoryNumber.Foreground = Get-Brush "#007AFF"
        $StepInventoryText.Foreground = Get-Brush "#1D1D1F"
        $StepInventoryText.FontWeight = "SemiBold"
        $SafeModeText.Text = "L'inventario usa soltanto metadati. Seleziona i file da autorizzare per la revisione."
    } elseif ($Page -eq "Review") {
        $ReviewPage.Visibility = "Visible"
        $StepConfigurationNumber.Foreground = Get-Brush "#007AFF"
        $StepConfigurationText.Foreground = Get-Brush "#3A3A3C"
        $StepInventoryNumber.Foreground = Get-Brush "#007AFF"
        $StepInventoryText.Foreground = Get-Brush "#3A3A3C"
        $StepReview.Background = Get-Brush "#FFFFFF"
        $StepReviewNumber.Foreground = Get-Brush "#007AFF"
        $StepReviewText.Foreground = Get-Brush "#1D1D1F"
        $StepReviewText.FontWeight = "SemiBold"
        $SafeModeText.Text = "Le password sono mascherate per impostazione predefinita e visibili soltanto su richiesta; le modifiche restano in memoria."
    } else {
        $ImportPage.Visibility = "Visible"
        $StepConfigurationNumber.Foreground = Get-Brush "#007AFF"
        $StepConfigurationText.Foreground = Get-Brush "#3A3A3C"
        $StepInventoryNumber.Foreground = Get-Brush "#007AFF"
        $StepInventoryText.Foreground = Get-Brush "#3A3A3C"
        $StepReviewNumber.Foreground = Get-Brush "#007AFF"
        $StepReviewText.Foreground = Get-Brush "#3A3A3C"
        $StepImport.Background = Get-Brush "#FFFFFF"
        $StepImportNumber.Foreground = Get-Brush "#007AFF"
        $StepImportText.Foreground = Get-Brush "#1D1D1F"
        $StepImportText.FontWeight = "SemiBold"
        $SafeModeText.Text = "GPGAuth e OpenPGP vengono eseguiti localmente. Ogni scrittura richiede dry-run e conferma esplicita."
    }

    if ($Page -ne "Review") {
        if ($null -ne $script:ReviewResult) {
            $StepReviewNumber.Foreground = Get-Brush "#007AFF"
            $StepReviewText.Foreground = Get-Brush "#3A3A3C"
        } else {
            $StepReviewNumber.Foreground = Get-Brush "#8E8E93"
            $StepReviewText.Foreground = Get-Brush "#8E8E93"
        }
    }
    if ($Page -ne "Import") {
        if ($script:ImportCandidates.Count -gt 0) {
            $StepImportNumber.Foreground = Get-Brush "#007AFF"
            $StepImportText.Foreground = Get-Brush "#3A3A3C"
        } else {
            $StepImportNumber.Foreground = Get-Brush "#8E8E93"
            $StepImportText.Foreground = Get-Brush "#8E8E93"
        }
    }
    $StepReview.IsEnabled = ($Page -eq "Review" -or $null -ne $script:ReviewResult)
    $StepImport.IsEnabled = ($Page -eq "Import" -or $script:ImportCandidates.Count -gt 0)
}

function Set-InventoryFilters($Result) {
    $Clients = @("Tutti i clienti") + @($Result.by_client.PSObject.Properties.Name)
    $Formats = @("Tutti i formati") + @($Result.by_extension.PSObject.Properties.Name)
    $ClientFilter.ItemsSource = $Clients
    $FormatFilter.ItemsSource = $Formats
    $ClientFilter.SelectedIndex = 0
    $FormatFilter.SelectedIndex = 0
    $SearchBox.Text = ""
}

function Apply-InventoryFilters {
    if ($null -eq $script:InventoryResult) { return }

    $SelectedClient = [string]$ClientFilter.SelectedItem
    $SelectedFormat = [string]$FormatFilter.SelectedItem
    $Search = $SearchBox.Text.Trim()
    $Rows = New-Object System.Collections.ObjectModel.ObservableCollection[object]

    foreach ($Row in $script:AllInventoryRows) {
        if ($SelectedClient -and $SelectedClient -ne "Tutti i clienti" -and $Row.Client -ne $SelectedClient) { continue }
        if ($SelectedFormat -and $SelectedFormat -ne "Tutti i formati" -and $Row.Extension -ne $SelectedFormat) { continue }
        if ($Search) {
            $Haystack = "$($Row.Client) $($Row.RelativePath)"
            if ($Haystack.IndexOf($Search, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        }
        $Rows.Add($Row)
    }

    $FilesGrid.ItemsSource = $Rows
    $FilterStatus.Text = "$($Rows.Count) di $($script:AllInventoryRows.Count) file"
}

function Update-ReviewSelectionState {
    $Count = $FilesGrid.SelectedItems.Count
    $ReviewSelectionButton.Content = "Rivedi selezionati ($Count)"
    $ReviewSelectionButton.IsEnabled = ($Count -gt 0)
}

function Set-ReviewFilters {
    $ReviewStatusFilter.ItemsSource = @("Tutti i candidati", "Pronti", "Da completare")
    $ReviewStatusFilter.SelectedIndex = 0
    $ReviewSearchBox.Text = ""
}

function Apply-ReviewFilters {
    if ($null -eq $script:ReviewResult) { return }
    $SelectedStatus = [string]$ReviewStatusFilter.SelectedItem
    $Search = $ReviewSearchBox.Text.Trim()
    $Rows = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    foreach ($Row in $script:AllReviewRows) {
        if ($SelectedStatus -eq "Pronti" -and $Row.Status -ne "ready") { continue }
        if ($SelectedStatus -eq "Da completare" -and $Row.Status -ne "incomplete") { continue }
        if ($Search) {
            $Haystack = "$($Row.Client) $($Row.Title) $($Row.Username) $($Row.Uri) $($Row.Source)"
            if ($Haystack.IndexOf($Search, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        }
        $Rows.Add($Row)
    }
    $ReviewCandidatesGrid.ItemsSource = $Rows
    $ReviewFilterStatus.Text = "$($Rows.Count) di $($script:AllReviewRows.Count) candidati"
    Update-ImportSelectionState
}

function Show-ExcelPasswordDialog([string]$RelativePath, [switch]$Retry, [switch]$BuildOnly) {
    $Dialog = New-Object System.Windows.Window
    $Dialog.Title = if ($Retry) { "Password Excel non corretta" } else { "Password Excel richiesta" }
    $Dialog.Width = 560
    $Dialog.Height = 300
    $Dialog.MinWidth = 500
    $Dialog.MinHeight = 280
    $Dialog.WindowStartupLocation = "CenterOwner"
    if (-not $BuildOnly -and $Window.IsVisible) { $Dialog.Owner = $Window }
    Initialize-ModernDialog $Dialog

    $Layout = New-Object System.Windows.Controls.Grid
    $Layout.Margin = [System.Windows.Thickness]::new(22)
    foreach ($Height in @("Auto", "Auto", "Auto", "*", "Auto")) {
        $Definition = New-Object System.Windows.Controls.RowDefinition
        $Definition.Height = if ($Height -eq "*") { [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) } else { [System.Windows.GridLength]::Auto }
        [void]$Layout.RowDefinitions.Add($Definition)
    }

    $Title = New-Object System.Windows.Controls.TextBlock
    $Title.Text = if ($Retry) { "La password inserita non ha aperto il file" } else { "Questo file Excel e' protetto da password" }
    $Title.FontSize = 20
    $Title.FontWeight = "Bold"
    [void]$Layout.Children.Add($Title)
    $Description = New-Object System.Windows.Controls.TextBlock
    $Description.Text = "$RelativePath`nInserisci la password del file. Verra' usata soltanto in memoria per revisione, controlli di integrita' e importazione."
    $Description.TextWrapping = "Wrap"
    $Description.Foreground = Get-Brush "#66737F"
    $Description.Margin = [System.Windows.Thickness]::new(0, 7, 0, 14)
    [System.Windows.Controls.Grid]::SetRow($Description, 1)
    [void]$Layout.Children.Add($Description)

    $PasswordHost = New-Object System.Windows.Controls.Grid
    [System.Windows.Controls.Grid]::SetRow($PasswordHost, 2)
    $PasswordBox = New-Object System.Windows.Controls.PasswordBox
    $PasswordBox.MaxLength = 1024
    [System.Windows.Automation.AutomationProperties]::SetName($PasswordBox, "Password file Excel")
    $PasswordText = New-Object System.Windows.Controls.TextBox
    $PasswordText.MaxLength = 1024
    $PasswordText.Visibility = "Collapsed"
    [System.Windows.Automation.AutomationProperties]::SetName($PasswordText, "Password file Excel visibile")
    [void]$PasswordHost.Children.Add($PasswordBox)
    [void]$PasswordHost.Children.Add($PasswordText)
    [void]$Layout.Children.Add($PasswordHost)

    $ShowPassword = New-Object System.Windows.Controls.CheckBox
    $ShowPassword.Content = "Mostra password durante l'inserimento"
    $ShowPassword.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
    [System.Windows.Controls.Grid]::SetRow($ShowPassword, 3)
    $ShowPassword.VerticalAlignment = "Top"
    $ShowPassword.Add_Checked({
        $PasswordText.Text = $PasswordBox.Password
        $PasswordBox.Visibility = "Collapsed"
        $PasswordText.Visibility = "Visible"
        $PasswordText.Focus() | Out-Null
        $PasswordText.CaretIndex = $PasswordText.Text.Length
    })
    $ShowPassword.Add_Unchecked({
        $PasswordBox.Password = $PasswordText.Text
        $PasswordText.Visibility = "Collapsed"
        $PasswordBox.Visibility = "Visible"
        $PasswordBox.Focus() | Out-Null
    })
    [void]$Layout.Children.Add($ShowPassword)

    $Footer = New-Object System.Windows.Controls.StackPanel
    $Footer.Orientation = "Horizontal"
    $Footer.HorizontalAlignment = "Right"
    [System.Windows.Controls.Grid]::SetRow($Footer, 4)
    $CancelButton = New-Object System.Windows.Controls.Button
    $CancelButton.Content = "Annulla revisione"
    $CancelButton.IsCancel = $true
    $CancelButton.Padding = [System.Windows.Thickness]::new(16, 8, 16, 8)
    $CancelButton.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $CancelButton.Add_Click({ $Dialog.DialogResult = $false })
    $ContinueButton = New-Object System.Windows.Controls.Button
    $ContinueButton.Content = "Apri file Excel"
    $ContinueButton.IsDefault = $true
    $ContinueButton.Padding = [System.Windows.Thickness]::new(16, 8, 16, 8)
    $ContinueButton.Style = $Window.FindResource("PrimaryButton")
    $ContinueButton.Foreground = Get-Brush "#FFFFFF"
    $ContinueButton.BorderThickness = [System.Windows.Thickness]::new(0)
    $ContinueButton.Add_Click({
        $Password = if ([bool]$ShowPassword.IsChecked) { [string]$PasswordText.Text } else { [string]$PasswordBox.Password }
        if (-not $Password) {
            [System.Windows.MessageBox]::Show("Inserire la password del file Excel.", "Password mancante", "OK", "Warning") | Out-Null
            return
        }
        $Dialog.Tag = $Password
        $Dialog.DialogResult = $true
    })
    [void]$Footer.Children.Add($CancelButton)
    [void]$Footer.Children.Add($ContinueButton)
    [void]$Layout.Children.Add($Footer)
    $Dialog.Content = $Layout

    if ($BuildOnly) {
        return [pscustomobject]@{ Window = $Dialog; PasswordBox = $PasswordBox; PasswordText = $PasswordText; ShowPassword = $ShowPassword }
    }
    $PasswordBox.Focus() | Out-Null
    if ($Dialog.ShowDialog() -ne $true) {
        $PasswordBox.Clear()
        $PasswordText.Text = ""
        return $null
    }
    $Result = [string]$Dialog.Tag
    $Dialog.Tag = $null
    $PasswordBox.Clear()
    $PasswordText.Text = ""
    return $Result
}

function ConvertTo-SourceProfileAliases([string]$Value) {
    return @(
        $Value -split "[,;`r`n]+" |
            ForEach-Object { ([string]$_).Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Get-SourceMappingProfileFromEditors([hashtable]$Editors) {
    return [pscustomobject][ordered]@{
        schema_version = 1
        name = ([string]$Editors.Name.Text).Trim()
        fields = [pscustomobject][ordered]@{
            title = @(ConvertTo-SourceProfileAliases ([string]$Editors.Title.Text))
            username = @(ConvertTo-SourceProfileAliases ([string]$Editors.Username.Text))
            secret = @(ConvertTo-SourceProfileAliases ([string]$Editors.Secret.Text))
            uri = @(ConvertTo-SourceProfileAliases ([string]$Editors.Uri.Text))
        }
    }
}

function Start-SourceMappingProfileValidation(
    [object]$Profile,
    [System.Windows.Window]$Dialog,
    [hashtable]$Editors,
    [ValidateSet("load", "save", "apply")][string]$Action
) {
    $OperationParameters = @{
        Name = "Validazione profilo sorgente"
        Category = "verify"
        WorkKind = "SecureJsonProcess"
        Payload = New-SecureJsonOperationPayload $PythonExecutable @($ReviewScript, "--profile-check") $Profile
        InteractiveSurface = $Dialog
        Context = [pscustomobject]@{ Dialog = $Dialog; Editors = $Editors; Action = $Action }
        OnSuccess = {
            param($Envelope, $Operation)
            try {
                if (-not [bool]$Envelope.ok) { throw (Get-SecureErrorMessage $Envelope) }
                $Canonical = $Envelope.result.profile
                if ($null -eq $Canonical -or -not [string]$Canonical.digest) { throw "Il validatore non ha restituito un profilo sorgente verificabile." }
                switch ([string]$Operation.Context.Action) {
                    "load" { Set-SourceMappingProfileEditors $Operation.Context.Editors $Canonical }
                    "save" {
                        $Picker = New-Object System.Windows.Forms.SaveFileDialog
                        $Picker.Title = "Salva profilo sorgente"
                        $Picker.Filter = "Profili JSON (*.json)|*.json"
                        $Picker.DefaultExt = "json"
                        $Picker.AddExtension = $true
                        $Picker.OverwritePrompt = $true
                        $Picker.FileName = "profilo-sorgente.json"
                        try {
                            if ($Picker.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                                $Json = $Canonical | ConvertTo-Json -Depth 6
                                [IO.File]::WriteAllText($Picker.FileName, $Json, (New-Object System.Text.UTF8Encoding($false)))
                            }
                        } finally { $Picker.Dispose() }
                    }
                    "apply" {
                        $Operation.Context.Dialog.Tag = [pscustomobject]@{ Reset = $false; Profile = $Canonical }
                        $Operation.Context.Dialog.DialogResult = $true
                    }
                }
            } catch {
                [System.Windows.MessageBox]::Show($_.Exception.Message, "Profilo non valido", "OK", "Error") | Out-Null
            }
        }
        OnFailure = {
            param($FailureMessage, $Operation)
            [System.Windows.MessageBox]::Show($FailureMessage, "Profilo non valido", "OK", "Error") | Out-Null
        }
    }
    [void](Start-UiOperation @OperationParameters)
}

function Set-SourceMappingProfileEditors([hashtable]$Editors, $Profile) {
    if ($null -eq $Profile) {
        $Editors.Name.Text = "Profilo personalizzato"
        $Editors.Title.Text = ""
        $Editors.Username.Text = ""
        $Editors.Secret.Text = ""
        $Editors.Uri.Text = ""
        return
    }
    $Editors.Name.Text = [string]$Profile.name
    $Editors.Title.Text = @($Profile.fields.title) -join ", "
    $Editors.Username.Text = @($Profile.fields.username) -join ", "
    $Editors.Secret.Text = @($Profile.fields.secret) -join ", "
    $Editors.Uri.Text = @($Profile.fields.uri) -join ", "
}

function Show-SourceMappingProfileDialog([switch]$BuildOnly) {
    $Dialog = New-Object System.Windows.Window
    $Dialog.Title = "Profilo di mappatura sorgente"
    if (-not $BuildOnly -and $Window.IsVisible) { $Dialog.Owner = $Window }
    $Dialog.WindowStartupLocation = "CenterOwner"
    $Dialog.ResizeMode = "NoResize"
    $Dialog.Width = 720
    $Dialog.Height = 600
    $Dialog.Background = Get-Brush "#F2F2F7"
    $Dialog.FontFamily = $Window.FontFamily

    $Layout = New-Object System.Windows.Controls.Grid
    $Layout.Margin = [System.Windows.Thickness]::new(24)
    $Layout.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = "Auto" }))
    $Layout.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = "*" }))
    $Layout.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = "Auto" }))

    $Header = New-Object System.Windows.Controls.StackPanel
    [System.Windows.Controls.Grid]::SetRow($Header, 0)
    $HeaderTitle = New-Object System.Windows.Controls.TextBlock
    $HeaderTitle.Text = "Associa le etichette dei documenti ai campi Passbolt"
    $HeaderTitle.FontSize = 21
    $HeaderTitle.FontWeight = "SemiBold"
    $HeaderTitle.Foreground = Get-Brush "#1D1D1F"
    $HeaderText = New-Object System.Windows.Controls.TextBlock
    $HeaderText.Text = "Inserisci una o piu etichette separate da virgola. Il confronto e esatto dopo la normalizzazione; il profilo contiene soltanto nomi di campo, mai valori o password."
    $HeaderText.TextWrapping = "Wrap"
    $HeaderText.Foreground = Get-Brush "#66737F"
    $HeaderText.Margin = [System.Windows.Thickness]::new(0, 6, 0, 16)
    [void]$Header.Children.Add($HeaderTitle)
    [void]$Header.Children.Add($HeaderText)
    [void]$Layout.Children.Add($Header)

    $Form = New-Object System.Windows.Controls.Grid
    [System.Windows.Controls.Grid]::SetRow($Form, 1)
    $Form.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = 170 }))
    $Form.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = "*" }))
    $Editors = @{}
    $Rows = @(
        [pscustomobject]@{ Key = "Name"; Label = "Nome profilo"; Hint = "Esempio: Export password manager" },
        [pscustomobject]@{ Key = "Title"; Label = "Titolo"; Hint = "Esempio: label, entry_name" },
        [pscustomobject]@{ Key = "Username"; Label = "Username"; Hint = "Esempio: account_name, login_id" },
        [pscustomobject]@{ Key = "Secret"; Label = "Password"; Hint = "Obbligatorio; esempio: credential_value" },
        [pscustomobject]@{ Key = "Uri"; Label = "URL / host"; Hint = "Esempio: target, endpoint" }
    )
    for ($Index = 0; $Index -lt $Rows.Count; $Index++) {
        $Form.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = "Auto" }))
        $Label = New-Object System.Windows.Controls.TextBlock
        $Label.Text = [string]$Rows[$Index].Label
        $Label.FontWeight = "SemiBold"
        $Label.Foreground = Get-Brush "#3A3A3C"
        $Label.Margin = [System.Windows.Thickness]::new(0, 10, 12, 12)
        [System.Windows.Controls.Grid]::SetRow($Label, $Index)
        [System.Windows.Controls.Grid]::SetColumn($Label, 0)
        $Editor = New-Object System.Windows.Controls.TextBox
        $Editor.ToolTip = [string]$Rows[$Index].Hint
        $Editor.Margin = [System.Windows.Thickness]::new(0, 4, 0, 8)
        $Editor.Padding = [System.Windows.Thickness]::new(10, 8, 10, 8)
        $Editor.MaxLength = 720
        [System.Windows.Automation.AutomationProperties]::SetName($Editor, "$([string]$Rows[$Index].Label) profilo sorgente")
        [System.Windows.Controls.Grid]::SetRow($Editor, $Index)
        [System.Windows.Controls.Grid]::SetColumn($Editor, 1)
        [void]$Form.Children.Add($Label)
        [void]$Form.Children.Add($Editor)
        $Editors[[string]$Rows[$Index].Key] = $Editor
    }
    Set-SourceMappingProfileEditors $Editors $script:SourceMappingProfile
    [void]$Layout.Children.Add($Form)

    $Footer = New-Object System.Windows.Controls.Grid
    $Footer.Margin = [System.Windows.Thickness]::new(0, 16, 0, 0)
    $Footer.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = "Auto" }))
    $Footer.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = "Auto" }))
    $Footer.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = "*" }))
    $Footer.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = "Auto" }))
    $Footer.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = "Auto" }))
    [System.Windows.Controls.Grid]::SetRow($Footer, 2)

    $LoadButton = New-Object System.Windows.Controls.Button
    $LoadButton.Content = "Carica JSON..."
    $LoadButton.Style = $Window.FindResource("SecondaryButton")
    $LoadButton.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    [System.Windows.Controls.Grid]::SetColumn($LoadButton, 0)
    $SaveButton = New-Object System.Windows.Controls.Button
    $SaveButton.Content = "Salva JSON..."
    $SaveButton.Style = $Window.FindResource("SecondaryButton")
    [System.Windows.Controls.Grid]::SetColumn($SaveButton, 1)
    $ResetButton = New-Object System.Windows.Controls.Button
    $ResetButton.Content = "Usa automatico"
    $ResetButton.Style = $Window.FindResource("SecondaryButton")
    $ResetButton.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    [System.Windows.Controls.Grid]::SetColumn($ResetButton, 3)
    $ApplyButton = New-Object System.Windows.Controls.Button
    $ApplyButton.Content = "Applica profilo"
    $ApplyButton.Style = $Window.FindResource("PrimaryButton")
    $ApplyButton.IsDefault = $true
    [System.Windows.Controls.Grid]::SetColumn($ApplyButton, 4)

    $LoadButton.Add_Click({
        $Picker = New-Object System.Windows.Forms.OpenFileDialog
        $Picker.Title = "Carica profilo sorgente"
        $Picker.Filter = "Profili JSON (*.json)|*.json"
        $Picker.CheckFileExists = $true
        try {
            if ($Picker.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
            $Info = Get-Item -LiteralPath $Picker.FileName -ErrorAction Stop
            if ($Info.Length -gt 16384) { throw "Il profilo supera il limite di 16 KiB." }
            $Loaded = [IO.File]::ReadAllText($Picker.FileName) | ConvertFrom-Json
            Start-SourceMappingProfileValidation $Loaded $Dialog $Editors "load"
        } catch {
            [System.Windows.MessageBox]::Show($_.Exception.Message, "Profilo non valido", "OK", "Error") | Out-Null
        } finally {
            $Picker.Dispose()
        }
    })
    $SaveButton.Add_Click({
        try {
            Start-SourceMappingProfileValidation (Get-SourceMappingProfileFromEditors $Editors) $Dialog $Editors "save"
        } catch {
            [System.Windows.MessageBox]::Show($_.Exception.Message, "Profilo non valido", "OK", "Error") | Out-Null
        }
    })
    $ResetButton.Add_Click({
        $Dialog.Tag = [pscustomobject]@{ Reset = $true; Profile = $null }
        $Dialog.DialogResult = $true
    })
    $ApplyButton.Add_Click({
        try {
            Start-SourceMappingProfileValidation (Get-SourceMappingProfileFromEditors $Editors) $Dialog $Editors "apply"
        } catch {
            [System.Windows.MessageBox]::Show($_.Exception.Message, "Profilo non valido", "OK", "Error") | Out-Null
        }
    })
    [void]$Footer.Children.Add($LoadButton)
    [void]$Footer.Children.Add($SaveButton)
    [void]$Footer.Children.Add($ResetButton)
    [void]$Footer.Children.Add($ApplyButton)
    [void]$Layout.Children.Add($Footer)
    $Dialog.Content = $Layout

    if ($BuildOnly) {
        return [pscustomobject]@{
            Window = $Dialog
            Editors = $Editors
            ApplyButton = $ApplyButton
            ResetButton = $ResetButton
        }
    }
    if ($Dialog.ShowDialog() -ne $true) { return $null }
    return $Dialog.Tag
}

function Update-SourceMappingProfileState {
    if ($null -eq $script:SourceMappingProfile) {
        $SourceProfileButton.Content = "Profilo sorgente: Automatico"
        $SourceProfileButton.ToolTip = "Usa gli alias integrati in italiano e inglese"
    } else {
        $ProfileName = [string]$script:SourceMappingProfile.name
        if ($ProfileName.Length -gt 28) { $ProfileName = $ProfileName.Substring(0, 28) + [char]0x2026 }
        $SourceProfileButton.Content = "Profilo sorgente: $ProfileName"
        $SourceProfileButton.ToolTip = "Mapping esatto verificato; digest $([string]$script:SourceMappingProfile.digest)"
    }
}

function Reset-ReviewForSourceMappingChange {
    Set-ReviewPasswordsVisible $false
    $script:ReviewResult = $null
    $script:AllReviewRows = @()
    $script:ReviewedSourceFiles = @()
    $script:ReviewFilePasswords = @{}
    $script:PendingProjectSelectedCandidates = @()
    $ReviewCandidatesGrid.ItemsSource = $null
    $ReviewSummary.Text = "Profilo sorgente modificato: ripetere la revisione"
    $ReviewMetricFiles.Text = [string][char]0x2014
    $ReviewMetricCandidates.Text = [string][char]0x2014
    $ReviewMetricReady.Text = [string][char]0x2014
    $ReviewMetricIncomplete.Text = [string][char]0x2014
    $ReviewWarningsPanel.Visibility = "Collapsed"
    Update-SourceFeedbackState
    Reset-ImportWorkflow
    $StepReviewNumber.Foreground = Get-Brush "#8E8E93"
    $StepReviewText.Foreground = Get-Brush "#8E8E93"
}

function Complete-SelectedReviewFailure([string]$FailureMessage, [object]$Context) {
    $script:ReviewFilePasswords = @{}
    if ($null -ne $Context -and $null -ne $Context.Passwords) { $Context.Passwords.Clear() }
    Add-Activity "Revisione non riuscita: $FailureMessage"
    Update-ReviewSelectionState
    [System.Windows.MessageBox]::Show($FailureMessage, "Revisione non riuscita", "OK", "Error") | Out-Null
}

function Set-SelectedReviewResult([object]$Result, [object]$Context) {
    $script:ReviewFilePasswords = @{}
    foreach ($RelativePath in $Context.Passwords.Keys) {
        $script:ReviewFilePasswords[[string]$RelativePath] = [string]$Context.Passwords[$RelativePath]
    }
    $Context.Passwords.Clear()
    $ReviewRows = New-Object System.Collections.Generic.List[object]
    if ($null -ne $Result.candidates) {
        foreach ($Candidate in @($Result.candidates)) {
            $StatusLabel = if ($Candidate.status -eq "ready") { "Pronto" } else { "Da completare" }
            $SecretDisplay = if ($Candidate.secret_present) { "******** ($($Candidate.secret_length))" } else { "Mancante" }
            $SourceAtRoot = -not [bool][System.IO.Path]::GetDirectoryName([string]$Candidate.source_relative_path)
            $Row = [pscustomobject]@{
                CandidateId = [string]$Candidate.candidate_id
                Status = [string]$Candidate.status
                StatusLabel = $StatusLabel
                Client = [string]$Candidate.client
                Title = [string]$Candidate.title
                Username = [string]$Candidate.username
                Uri = [string]$Candidate.uri
                OriginalClient = [string]$Candidate.client
                OriginalSourceAtRoot = $SourceAtRoot
                OriginalTitle = [string]$Candidate.title
                OriginalUsername = [string]$Candidate.username
                OriginalUri = [string]$Candidate.uri
                SecretPresent = [bool]$Candidate.secret_present
                SecretLength = [int]$Candidate.secret_length
                SecretValue = ""
                SecretCachedFromSource = $false
                PasswordOverridden = $false
                IsEdited = $false
                SourcePasswordRequired = [bool]$Candidate.source_password_required
                SecretDisplay = $SecretDisplay
                Source = "$($Candidate.source_relative_path) - $($Candidate.location)"
                SourceRelativePath = [string]$Candidate.source_relative_path
                Location = [string]$Candidate.location
                SourceHash = [string]$Candidate.source_sha256
                Confidence = [string]$Candidate.confidence
                SourceMappingDigest = [string]$Candidate.source_mapping_digest
                SourceMappingProfile = $Candidate.source_mapping_profile
            }
            Update-ReviewRowState $Row
            $ReviewRows.Add($Row)
        }
    }
    $script:ReviewResult = $Result
    $script:AllReviewRows = $ReviewRows.ToArray()
    $script:ReviewedSourceFiles = @($Context.SelectedFiles)
    Reset-ImportWorkflow
    $ReviewMetricFiles.Text = "$($Result.analyzed_files)/$($Result.selected_files)"
    Update-ReviewMetrics
    $MappingLabel = [string]$Result.source_mapping_profile_name
    $MappingSuffix = if ([string]$Result.source_mapping_profile_digest) {
        $MappingDigestPrefix = ([string]$Result.source_mapping_profile_digest).Substring(0, 8).ToUpperInvariant()
        "; mapping $MappingLabel / $MappingDigestPrefix"
    } else { "; rilevamento automatico" }
    $ReviewSummary.Text = "Revisione locale completata $(Get-Date -Format 'dd/MM/yyyy HH:mm')$MappingSuffix"
    Set-ReviewFilters
    Apply-ReviewFilters
    Apply-PendingProjectCandidateSelection

    $WarningItems = @($Result.warnings)
    if ($WarningItems.Count -gt 0) {
        $ShownWarnings = @($WarningItems | Select-Object -First 5)
        $ReviewWarningsText.Text = $ShownWarnings -join [Environment]::NewLine
        if ($WarningItems.Count -gt 5) {
            $ReviewWarningsText.Text += [Environment]::NewLine + "... e altri $($WarningItems.Count - 5) avvisi."
        }
        $ReviewWarningsPanel.Visibility = "Visible"
    } else {
        $ReviewWarningsPanel.Visibility = "Collapsed"
    }
    Add-Activity "Revisione completata: $($Result.candidate_count) candidati; valori segreti non registrati."
    Update-ReviewSelectionState
    Update-SourceFeedbackState
    Show-Page "Review"
}

function Start-SelectedReviewAttempt([object]$Context) {
    $PasswordEntries = New-Object System.Collections.Generic.List[object]
    foreach ($RelativePath in @($Context.Passwords.Keys | Sort-Object)) {
        $PasswordEntries.Add([pscustomobject][ordered]@{
            relative_path = [string]$RelativePath
            password = [string]$Context.Passwords[$RelativePath]
        })
    }
    $Request = [pscustomobject]@{
        files = @($Context.SelectedFiles)
        file_passwords = $PasswordEntries.ToArray()
        source_mapping_profile = $script:SourceMappingProfile
    }
    $OperationParameters = @{
        Name = "Revisione locale documenti"
        Category = "read"
        WorkKind = "SecureJsonProcess"
        Payload = New-SecureJsonOperationPayload $PythonExecutable @($ReviewScript, "--secure-json", "--root", $script:InventoryFolder) $Request 180000
        Context = $Context
        OnSuccess = {
            param($Envelope, $Operation)
            if (-not [bool]$Envelope.ok) {
                Complete-SelectedReviewFailure (Get-SecureErrorMessage $Envelope) $Operation.Context
                return
            }
            $Result = $Envelope.result
            $Issues = @($Result.protected_excel_issues)
            if ($Issues.Count -gt 0) {
                $Operation.Context.PromptAttempts = [int]$Operation.Context.PromptAttempts + 1
                if ([int]$Operation.Context.PromptAttempts -gt 10) {
                    Complete-SelectedReviewFailure "Impossibile completare la lettura dei file Excel protetti dopo troppi tentativi." $Operation.Context
                    return
                }
                foreach ($Issue in $Issues) {
                    $RelativePath = [string]$Issue.relative_path
                    $IssueStatus = [string]$Issue.status
                    if ($IssueStatus -eq "reader_unavailable") {
                        Complete-SelectedReviewFailure "Il lettore dei file Excel cifrati non e' installato. Eseguire: python -m pip install -r requirements.txt" $Operation.Context
                        return
                    }
                    if ($IssueStatus -notin @("password_required", "password_rejected")) {
                        Complete-SelectedReviewFailure "Il file Excel protetto $RelativePath non puo essere letto in sicurezza." $Operation.Context
                        return
                    }
                    $Password = Show-ExcelPasswordDialog $RelativePath -Retry:($IssueStatus -eq "password_rejected")
                    if ($null -eq $Password) {
                        $Operation.Context.Passwords.Clear()
                        Add-Activity "Revisione annullata durante la richiesta della password di un file Excel."
                        Update-ReviewSelectionState
                        return
                    }
                    $Operation.Context.Passwords[$RelativePath] = [string]$Password
                    $Password = $null
                }
                Add-Activity "Nuovo tentativo di lettura locale di $($Operation.Context.Passwords.Count) file Excel protetti; nessuna password e' stata registrata."
                Start-SelectedReviewAttempt $Operation.Context
                return
            }
            try { Set-SelectedReviewResult $Result $Operation.Context }
            catch { Complete-SelectedReviewFailure ([string]$_.Exception.Message) $Operation.Context }
        }
        OnFailure = {
            param($FailureMessage, $Operation)
            Complete-SelectedReviewFailure $FailureMessage $Operation.Context
        }
    }
    [void](Start-UiOperation @OperationParameters)
}

function Invoke-SelectedReview {
    $SelectedCount = $FilesGrid.SelectedItems.Count
    if ($SelectedCount -lt 1) { return }
    $Decision = [System.Windows.MessageBox]::Show(
        "La revisione aprira' localmente soltanto i $SelectedCount file selezionati. Le password saranno riconosciute in memoria ma resteranno mascherate e non verranno salvate. Continuare?",
        "Autorizza analisi locale",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($Decision -ne [System.Windows.MessageBoxResult]::Yes) { return }

    Set-ReviewPasswordsVisible $false
    $SelectedFiles = New-Object System.Collections.Generic.List[string]
    foreach ($SelectedItem in $FilesGrid.SelectedItems) {
        $SelectedFiles.Add([string]$SelectedItem.RelativePath)
    }
    $script:ReviewFilePasswords = @{}
    $Context = [pscustomobject]@{
        SelectedFiles = $SelectedFiles.ToArray()
        Passwords = @{}
        PromptAttempts = 0
    }
    $ReviewSelectionButton.Content = "Analisi locale in corso..."
    Add-Activity "Avvio revisione locale di $SelectedCount file selezionati."
    Start-SelectedReviewAttempt $Context
}
function Invoke-Inventory {
    $Folder = $ClientFolder.Text.Trim()
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) {
        [System.Windows.MessageBox]::Show("La cartella configurata non $([char]0x00E8) pi$([char]0x00F9) accessibile.", "Cartella non disponibile", "OK", "Warning") | Out-Null
        Show-Page "Configuration"
        Update-ConfigurationState
        return
    }

    $script:ReviewResult = $null
    $script:AllReviewRows = @()
    $script:ReviewedSourceFiles = @()
    $script:ReviewFilePasswords = @{}
    Update-SourceFeedbackState
    Reset-ImportWorkflow
    $ReviewCandidatesGrid.ItemsSource = $null
    $StepReviewNumber.Foreground = Get-Brush "#8E8E93"
    $StepReviewText.Foreground = Get-Brush "#8E8E93"
    $InventoryRoot.Text = "Analisi dei metadati in corso: $Folder"
    $FilesGrid.ItemsSource = $null
    $FilterStatus.Text = "Analisi in corso..."
    Add-Activity "Avvio inventario metadati."
    [void](Start-UiOperation "Inventario metadati" "read" "PythonJson" `
        (New-PythonJsonOperationPayload $InventoryScript @("--inventory", $Folder, "--json")) `
        -Context ([pscustomobject]@{ Folder = $Folder }) `
        -OnSuccess {
            param($Result, $Operation)
            $script:InventoryResult = $Result
            $script:InventoryFolder = [string]$Operation.Context.Folder
            $RowList = New-Object System.Collections.Generic.List[object]
            if ($null -ne $Result.items) {
                foreach ($Item in @($Result.items)) {
                    $Modified = ""
                    if ($Item.modified_utc) {
                        try { $Modified = ([DateTimeOffset]::Parse([string]$Item.modified_utc)).ToLocalTime().ToString("dd/MM/yyyy HH:mm") } catch { $Modified = [string]$Item.modified_utc }
                    }
                    $RowList.Add([pscustomobject]@{
                        Client = [string]$Item.client
                        RelativePath = [string]$Item.relative_path
                        Extension = [string]$Item.extension
                        Category = [string]$Item.category
                        Size = Format-Size ([long]$Item.size_bytes)
                        SizeBytes = [long]$Item.size_bytes
                        Modified = $Modified
                        IsLink = [bool]$Item.is_link
                    })
                }
            }
            $script:AllInventoryRows = $RowList.ToArray()
            $MetricClients.Text = [string]$Result.client_folders
            $MetricFiles.Text = [string]$Result.supported_files
            $MetricSize.Text = Format-Size ([long]$Result.supported_bytes)
            $MetricIgnored.Text = [string]$Result.ignored_files
            $InventoryRoot.Text = "Cartella: $($Result.root) $([char]0x2022) inventario aggiornato $(Get-Date -Format 'dd/MM/yyyy HH:mm')"
            Set-InventoryFilters $Result
            Apply-InventoryFilters
            Apply-PendingProjectInventorySelection
            $ErrorCount = @($Result.access_errors).Count
            $LinkCount = @($script:AllInventoryRows | Where-Object { $_.IsLink }).Count
            $DirectoryLinkCount = @($Result.skipped_directory_links).Count
            $Warnings = @()
            if ($ErrorCount -gt 0) { $Warnings += "$ErrorCount percorsi non accessibili: il report potrebbe essere incompleto." }
            if ($LinkCount -gt 0) { $Warnings += "$LinkCount collegamenti a file individuati; $([char]0x00E8) stato letto solo il metadato del collegamento." }
            if ($DirectoryLinkCount -gt 0) { $Warnings += "$DirectoryLinkCount collegamenti a cartelle ignorati per mantenere l'inventario entro la radice selezionata." }
            if ($Warnings.Count -gt 0) {
                $WarningsText.Text = $Warnings -join "  "
                $WarningsPanel.Visibility = "Visible"
            } else {
                $WarningsPanel.Visibility = "Collapsed"
            }
            Update-ConfigurationState
            Update-ReviewSelectionState
            Update-SourceFeedbackState
            Add-Activity "Inventario completato: $($Result.client_folders) clienti, $($Result.supported_files) file supportati, $($Result.ignored_files) ignorati."
        } `
        -OnFailure {
            param($FailureMessage, $Operation)
            $script:InventoryResult = $null
            $script:AllInventoryRows = @()
            $InventoryRoot.Text = "Inventario non riuscito"
            $FilterStatus.Text = "0 file"
            Update-ConfigurationState
            Update-ReviewSelectionState
            Update-SourceFeedbackState
            Add-Activity "Inventario non riuscito: $FailureMessage"
            [System.Windows.MessageBox]::Show($FailureMessage, "Inventario non riuscito", "OK", "Error") | Out-Null
        })
}

$PlannedPassboltUrl.Add_TextChanged({
    if (-not $script:SynchronizingPassboltUrl) {
        $script:SynchronizingPassboltUrl = $true
        try {
            if ($PassboltUrl.Text -cne $PlannedPassboltUrl.Text) { $PassboltUrl.Text = $PlannedPassboltUrl.Text }
        } finally {
            $script:SynchronizingPassboltUrl = $false
        }
    }
    Update-ConfigurationState
})

$PassboltUrl.Add_TextChanged({
    if (-not $script:SynchronizingPassboltUrl) {
        $script:SynchronizingPassboltUrl = $true
        try {
            if ($PlannedPassboltUrl.Text -cne $PassboltUrl.Text) { $PlannedPassboltUrl.Text = $PassboltUrl.Text }
        } finally {
            $script:SynchronizingPassboltUrl = $false
        }
    }
    $VerifyButton.IsEnabled = [bool]$PassboltUrl.Text.Trim()
    if ($script:VerifiedUrl -and $PassboltUrl.Text.Trim() -ne $script:VerifiedUrl) {
        if (Test-ImportSessionActive) {
            Stop-ImportSession "Sessione chiusa perche' l'URL Passbolt e' stato modificato." $false
        }
        $script:ConnectionVerified = $false
        $script:VerifiedUrl = ""
        $script:VerifiedFingerprint = ""
        $DetectedFingerprint.Text = "Fingerprint: non ancora rilevata"
        Reset-ImportPlan "URL Passbolt modificato. Ripetere connessione e dry-run."
        $script:ClientDestinationMap = @{}
        $script:PermissionMode = "inherited"
        $script:PermissionTemplate = @()
        $script:PermissionCatalog = @()
        $script:PermissionCatalogSessionId = ""
        Update-PermissionEditorState
        Update-DestinationFolderOptions @() "" $false
        $ConnectionDot.Fill = Get-Brush "#AEAEB2"
        $ConnectionStatus.Text = "URL modificato: ripeti la verifica"
        $ConnectionStatus.Foreground = Get-Brush "#6E6E73"
        Update-ConfigurationState
    }
})

$VerifyButton.Add_Click({
    $ConnectionDot.Fill = Get-Brush "#C77D00"
    $ConnectionStatus.Text = "Verifica in corso..."
    $ConnectionStatus.Foreground = Get-Brush "#C77D00"
    Add-Activity "Avvio verifica pubblica dell'istanza Passbolt."
    $Url = $PassboltUrl.Text.Trim()
    [void](Start-UiOperation "Verifica pubblica Passbolt" "verify" "PythonJson" `
        (New-PythonJsonOperationPayload $ProbeScript @("--base-url", $Url, "--discover-fingerprint", "--json")) `
        -OnSuccess {
            param($Result, $Operation)
            try {
                $DetectedValue = ([string]$Result.fingerprint).Trim().ToUpperInvariant()
                if ($DetectedValue -notmatch '^[0-9A-F]{40}$') { throw "La fingerprint rilevata dal server non e' valida." }
                $DetectedFingerprint.Text = "Fingerprint: $DetectedValue"
                $ConfirmationMessage = "Fingerprint OpenPGP rilevata:`n`n$DetectedValue`n`nIl valore e' stato fornito dall'istanza appena contattata. Il rilevamento automatico non dimostra da solo l'identita' del server. Alla prima connessione, confrontarlo con l'amministratore tramite un canale indipendente.`n`nConfermare questa fingerprint per la sessione corrente?"
                $Confirmation = [System.Windows.MessageBox]::Show($ConfirmationMessage, "Conferma fingerprint Passbolt", "YesNo", "Warning")
                if ([string]$Confirmation -ne "Yes") {
                    if (Test-ImportSessionActive) { Stop-ImportSession "Sessione chiusa perche' la fingerprint Passbolt rilevata non e' stata confermata." $false }
                    $script:ConnectionVerified = $false
                    $script:VerifiedUrl = ""
                    $script:VerifiedFingerprint = ""
                    Reset-ImportPlan "Fingerprint Passbolt non confermata. Ripetere la verifica."
                    $script:ClientDestinationMap = @{}
                    Update-DestinationFolderOptions @() "" $false
                    $ConnectionDot.Fill = Get-Brush "#C77D00"
                    $ConnectionStatus.Text = "Fingerprint rilevata ma non confermata"
                    $ConnectionStatus.Foreground = Get-Brush "#C77D00"
                    Add-Activity "Fingerprint Passbolt rilevata ma non confermata; connessione non autorizzata."
                    return
                }
                if ((Test-ImportSessionActive) -and $script:VerifiedFingerprint -and $script:VerifiedFingerprint -ne $DetectedValue) {
                    Stop-ImportSession "Sessione chiusa perche' la fingerprint Passbolt rilevata e' cambiata." $false
                }
                $script:ConnectionVerified = $true
                $script:VerifiedUrl = [string]$Result.base_url
                $script:VerifiedFingerprint = $DetectedValue
                if ($null -ne $script:ImportPlan) { Reset-ImportPlan "Connessione riverificata. Ripetere il dry-run autenticato." }
                $ConnectionDot.Fill = Get-Brush "#248A3D"
                $ConnectionStatus.Text = "Server verificato e fingerprint confermata"
                $ConnectionStatus.Foreground = Get-Brush "#248A3D"
                Add-Activity "Passbolt raggiungibile; healthcheck verificato e fingerprint rilevata confermata dall'utente."
            } catch {
                $FailureMessage = [string]$_.Exception.Message
                if (Test-ImportSessionActive) { Stop-ImportSession "Sessione chiusa perche' la verifica pubblica di Passbolt non e' riuscita." $false }
                $script:ConnectionVerified = $false
                $script:VerifiedUrl = ""
                $script:VerifiedFingerprint = ""
                $DetectedFingerprint.Text = "Fingerprint: non disponibile"
                Reset-ImportPlan "Verifica pubblica non riuscita. Ripetere connessione e dry-run."
                $ConnectionDot.Fill = Get-Brush "#D70015"
                $ConnectionStatus.Text = "Verifica non riuscita"
                $ConnectionStatus.Foreground = Get-Brush "#D70015"
                Add-Activity "Verifica Passbolt non riuscita: $FailureMessage"
                [System.Windows.MessageBox]::Show($FailureMessage, "Connessione non riuscita", "OK", "Error") | Out-Null
            } finally {
                Update-ConfigurationState
                Update-ImportSessionState
            }
        } `
        -OnFailure {
            param($FailureMessage, $Operation)
            if (Test-ImportSessionActive) { Stop-ImportSession "Sessione chiusa perche' la verifica pubblica di Passbolt non e' riuscita." $false }
            $script:ConnectionVerified = $false
            $script:VerifiedUrl = ""
            $script:VerifiedFingerprint = ""
            $DetectedFingerprint.Text = "Fingerprint: non disponibile"
            Reset-ImportPlan "Verifica pubblica non riuscita. Ripetere connessione e dry-run."
            $ConnectionDot.Fill = Get-Brush "#D70015"
            $ConnectionStatus.Text = "Verifica non riuscita"
            $ConnectionStatus.Foreground = Get-Brush "#D70015"
            Add-Activity "Verifica Passbolt non riuscita: $FailureMessage"
            Update-ConfigurationState
            Update-ImportSessionState
            [System.Windows.MessageBox]::Show($FailureMessage, "Connessione non riuscita", "OK", "Error") | Out-Null
        })
})

$ClientFolder.Add_TextChanged({
    Update-ConfigurationState
    if (
        $script:PendingProjectSourceRoot -and
        -not [string]::Equals($ClientFolder.Text.Trim(), $script:PendingProjectSourceRoot, [StringComparison]::OrdinalIgnoreCase)
    ) {
        $script:PendingProjectSourceRoot = ""
        $script:PendingProjectSelectedFiles = @()
        $script:PendingProjectSelectedCandidates = @()
        $script:LoadedProjectDigest = ""
        Add-Activity "Cartella sorgente modificata; le selezioni pendenti del progetto sono state invalidate."
    }
    if ($script:InventoryFolder -and $ClientFolder.Text.Trim() -ne $script:InventoryFolder) {
        if (Test-ImportSessionActive) {
            Stop-ImportSession "Sessione chiusa perche' la cartella clienti e' stata modificata." $false
        }
        $script:InventoryResult = $null
        $script:AllInventoryRows = @()
        $script:ReviewResult = $null
        $script:AllReviewRows = @()
        $script:ReviewedSourceFiles = @()
        Reset-ImportWorkflow
        $StepReviewNumber.Foreground = Get-Brush "#8E8E93"
        $StepReviewText.Foreground = Get-Brush "#8E8E93"
    }
})

$BrowseButton.Add_Click({
    $Dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $Dialog.Description = "Seleziona la cartella principale dei documenti clienti"
    $Dialog.ShowNewFolderButton = $false
    if ($ClientFolder.Text.Trim() -and (Test-Path -LiteralPath $ClientFolder.Text.Trim() -PathType Container)) {
        $Dialog.SelectedPath = $ClientFolder.Text.Trim()
    }
    if ($Dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $ClientFolder.Text = $Dialog.SelectedPath
        Add-Activity "Cartella clienti selezionata. Nessun documento $([char]0x00E8) stato aperto."
    }
    $Dialog.Dispose()
})

$ContinueButton.Add_Click({
    if (-not (Test-SelectedFolder)) {
        [System.Windows.MessageBox]::Show("Selezionare una cartella locale valida.", "Preparazione incompleta", "OK", "Warning") | Out-Null
        return
    }
    Show-Page "Inventory"
    if ($null -eq $script:InventoryResult -or $script:InventoryFolder -ne $ClientFolder.Text.Trim()) {
        Invoke-Inventory
    } else {
        Apply-InventoryFilters
    }
})

$OpenProjectButton.Add_Click({ Open-LocalPreparationProject })
$SaveInventoryProjectButton.Add_Click({ Save-LocalPreparationProject })
$SaveReviewProjectButton.Add_Click({ Save-LocalPreparationProject -ReviewContext })
$BackButton.Add_Click({ Show-Page "Configuration"; Update-ConfigurationState })
$StepConfiguration.Add_Click({ Show-Page "Configuration"; Update-ConfigurationState })
$StepInventory.Add_Click({
    if (Test-SelectedFolder) {
        Show-Page "Inventory"
        if ($null -eq $script:InventoryResult -or $script:InventoryFolder -ne $ClientFolder.Text.Trim()) { Invoke-Inventory }
    }
})
$StepReview.Add_Click({
    if ($null -ne $script:ReviewResult) { Show-Page "Review" }
})
$StepImport.Add_Click({
    if ($script:ImportCandidates.Count -gt 0) { Show-Page "Import" }
})
$RefreshButton.Add_Click({ Invoke-Inventory })
$SourceFeedbackButton.Add_Click({ Invoke-SourceFeedback })
$ClientFilter.Add_SelectionChanged({ Apply-InventoryFilters })
$FormatFilter.Add_SelectionChanged({ Apply-InventoryFilters })
$SearchBox.Add_TextChanged({ Apply-InventoryFilters })
$FilesGrid.Add_SelectionChanged({ Update-ReviewSelectionState })
$SourceProfileButton.Add_Click({
    $ProfileResult = Show-SourceMappingProfileDialog
    if ($null -eq $ProfileResult) { return }
    $PreviousDigest = if ($null -eq $script:SourceMappingProfile) { "" } else { [string]$script:SourceMappingProfile.digest }
    $script:SourceMappingProfile = if ([bool]$ProfileResult.Reset) { $null } else { $ProfileResult.Profile }
    $CurrentDigest = if ($null -eq $script:SourceMappingProfile) { "" } else { [string]$script:SourceMappingProfile.digest }
    Update-SourceMappingProfileState
    if ($PreviousDigest -cne $CurrentDigest) {
        Reset-ReviewForSourceMappingChange
        Add-Activity "Profilo sorgente modificato; revisione e piani precedenti sono stati invalidati."
    }
})
$ReviewSelectionButton.Add_Click({ Invoke-SelectedReview })
$ReviewBackButton.Add_Click({ Show-Page "Inventory"; Apply-InventoryFilters })
$ReviewStatusFilter.Add_SelectionChanged({ Apply-ReviewFilters })
$ReviewSearchBox.Add_TextChanged({ Apply-ReviewFilters })
$ReviewCandidatesGrid.Add_SelectionChanged({ Update-ImportSelectionState })
$ReviewPasswordToggle.Add_Checked({
    if (-not $script:UpdatingReviewPasswordToggle) { Set-ReviewPasswordsVisible $true }
})
$ReviewPasswordToggle.Add_Unchecked({
    if (-not $script:UpdatingReviewPasswordToggle) { Set-ReviewPasswordsVisible $false }
})
$EditReviewCandidateButton.Add_Click({ Show-ReviewCandidateEditor })
$PrepareImportButton.Add_Click({ Open-ImportPreparation })
$ImportBackButton.Add_Click({ Show-Page "Review"; Apply-ReviewFilters })
$RecoveryBackButton.Add_Click({ Show-Page "Review"; Apply-ReviewFilters })
$AclBackButton.Add_Click({ Show-Page "Review"; Apply-ReviewFilters })
$RecoveryBatchesGrid.Add_SelectionChanged({ Set-RecoveryBatchSelection })
$RefreshRecoveryButton.Add_Click({ Refresh-RecoveryBatches })
$ArchiveRecoveryButton.Add_Click({ Invoke-ArchiveRecoveryBatch })
$RecoveryConfirmation.Add_TextChanged({ Update-RecoveryActionState })
$VerifyRecoveryButton.Add_Click({ Invoke-RecoveryReadiness })
$ExecuteRecoveryButton.Add_Click({ Invoke-ConfirmedRecovery })
$RefreshAclButton.Add_Click({ Refresh-ExistingAclCatalog })
$AclPlanButton.Add_Click({ Invoke-AclDryRun })
$AclConfirmation.Add_TextChanged({ Update-AclApplyActionState })
$ApplyAclButton.Add_Click({ Invoke-ConfirmedAclApply })
$RecoverAclButton.Add_Click({ Invoke-AclRecovery })
$ManageAclJournalsButton.Add_Click({ Show-AclJournalManager })
$AclTypeFilter.Add_SelectionChanged({ Update-AclObjectFilter })
$AclSearchBox.Add_TextChanged({ Update-AclObjectFilter })
$AclObjectsGrid.Add_SelectionChanged({ Update-AclPermissionDetail })
$NewImportModeButton.Add_Click({ Show-Phase04Workspace "new_import" })
$RecoveryModeButton.Add_Click({ Show-Phase04Workspace "recovery" })
$AclWorkspaceButton.Add_Click({
    if ($script:Phase04Workspace -eq "existing_acl") {
        Show-Phase04Workspace $script:LastMigrationWorkspace
    } else {
        Show-Phase04Workspace "existing_acl"
    }
})

$BrowseKeyButton.Add_Click({
    $Dialog = New-Object System.Windows.Forms.OpenFileDialog
    $Dialog.Title = "Seleziona la chiave privata OpenPGP di Passbolt"
    $Dialog.Filter = "Chiavi OpenPGP (*.asc;*.key)|*.asc;*.key|Tutti i file (*.*)|*.*"
    $Dialog.CheckFileExists = $true
    $Dialog.Multiselect = $false
    if ($PrivateKeyPath.Text.Trim() -and (Test-Path -LiteralPath $PrivateKeyPath.Text.Trim() -PathType Leaf)) {
        $Dialog.FileName = $PrivateKeyPath.Text.Trim()
    }
    try {
        if ($Dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $PrivateKeyPath.Text = $Dialog.FileName
            Add-Activity "File della chiave privata selezionato; il contenuto non e' stato copiato."
        }
    } finally {
        $Dialog.Dispose()
    }
})

$PrivateKeyPath.Add_TextChanged({
    if ($script:ImportPlanKeyPath -and $PrivateKeyPath.Text.Trim() -ne $script:ImportPlanKeyPath) {
        Reset-ImportPlan "Chiave privata modificata. Ripetere il dry-run."
    }
    Update-ExecuteImportState
})
$KeyPassphrase.Add_PasswordChanged({ Update-ImportSessionState })
$MfaTotpCode.Add_PasswordChanged({ Update-ImportSessionState })
$DestinationMode.Add_SelectionChanged({
    Update-DestinationControlState
    if ($null -ne $script:ImportPlan) {
        Reset-ImportPlan "La destinazione e' cambiata. Ripetere il dry-run."
        Add-Activity "Destinazione modificata; il piano precedente e' stato invalidato."
    }
})
$DestinationFolder.Add_SelectionChanged({
    if (-not $script:PopulatingDestinationFolders -and $null -ne $script:ImportPlan) {
        Reset-ImportPlan "La cartella Passbolt di destinazione e' cambiata. Ripetere il dry-run."
        Add-Activity "Cartella Passbolt modificata; il piano precedente e' stato invalidato."
    }
})
$ResourceFormat.Add_SelectionChanged({
    if ($null -ne $script:ImportPlan) {
        Reset-ImportPlan "Il formato delle risorse e' cambiato. Ripetere il dry-run."
        Add-Activity "Formato risorse modificato; il piano precedente e' stato invalidato."
    }
})
$ConfigureClientMappingsButton.Add_Click({ Show-ClientDestinationMappingDialog })
$ConfigurePermissionsButton.Add_Click({ Open-PermissionEditorAsync })
$ImportConfirmation.Add_TextChanged({ Update-ExecuteImportState })
$ImportSessionButton.Add_Click({
    if (Test-ImportSessionActive) {
        Close-ImportSessionAsync "Sessione autenticata chiusa dall'utente." $true
    } elseif ($null -ne $script:ImportSessionProcess -or $script:ImportSessionId) {
        Stop-ImportSession "La sessione locale non era piu disponibile ed e' stata ripulita. Avviarne una nuova." $true
    } else {
        Open-ImportSession
    }
})
$DryRunButton.Add_Click({ Invoke-ImportReadiness })
$ExecuteImportButton.Add_Click({ Invoke-ConfirmedImport })
$ExportPreflightReceiptButton.Add_Click({ Export-MigrationReceipt "preflight" })
$ExportMigrationReceiptButton.Add_Click({ Export-MigrationReceipt "migration" })

$ExportButton.Add_Click({
    if ($null -eq $script:InventoryResult) { return }
    $Dialog = New-Object System.Windows.Forms.SaveFileDialog
    $Dialog.Title = "Esporta inventario metadati"
    $Dialog.Filter = "File CSV (*.csv)|*.csv"
    $Dialog.DefaultExt = "csv"
    $Dialog.AddExtension = $true
    $Dialog.OverwritePrompt = $true
    $Dialog.FileName = "inventario-passbolt-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
    try {
        if ($Dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            Add-Activity "Esportazione CSV in corso."
            [void](Start-UiOperation "Esportazione inventario CSV" "read" "PythonJson" `
                (New-PythonJsonOperationPayload $InventoryScript @("--inventory", $script:InventoryFolder, "--csv", $Dialog.FileName, "--json")) `
                -OnSuccess {
                    param($ExportResult, $Operation)
                    Add-Activity "Report CSV esportato: $($ExportResult.csv_path)"
                    [System.Windows.MessageBox]::Show("Inventario esportato correttamente in:`n$($ExportResult.csv_path)", "Esportazione completata", "OK", "Information") | Out-Null
                } `
                -OnFailure {
                    param($FailureMessage, $Operation)
                    Add-Activity "Esportazione non riuscita: $FailureMessage"
                    [System.Windows.MessageBox]::Show($FailureMessage, "Esportazione non riuscita", "OK", "Error") | Out-Null
                })
        }
    } catch {
        Add-Activity "Esportazione non riuscita: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Esportazione non riuscita", "OK", "Error") | Out-Null
    } finally {
        $Dialog.Dispose()
    }
})

$script:OperationPollTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:OperationPollTimer.Interval = [TimeSpan]::FromMilliseconds(75)
$script:OperationPollTimer.Add_Tick({
    if (-not (Test-OperationActive)) { return }
    $Operation = $script:OperationalState.Active
    if ($null -eq $Operation) { return }
    Drain-OperationProgress $Operation
    if ($Operation.AsyncResult.IsCompleted) { Complete-UiOperation ([string]$Operation.OperationId) }
})
$script:OperationPollTimer.Start()

$script:ImportSessionTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:ImportSessionTimer.Interval = [TimeSpan]::FromMinutes(1)
$script:ImportSessionTimer.Add_Tick({
    if (Test-OperationActive) { return }
    if (($null -ne $script:ImportSessionProcess -or $script:ImportSessionId) -and -not (Test-ImportSessionActive)) {
        Stop-ImportSession "La sessione locale si e' chiusa inaspettatamente ed e' stata ripulita." $true
    } elseif ((Test-ImportSessionActive) -and $script:ImportSessionLastActivityUtc -ne [DateTime]::MinValue) {
        $IdleMinutes = ([DateTime]::UtcNow - $script:ImportSessionLastActivityUtc).TotalMinutes
        if ($IdleMinutes -ge $script:ImportSessionIdleTimeoutMinutes) {
            Close-ImportSessionAsync "Sessione autenticata chiusa automaticamente dopo $($script:ImportSessionIdleTimeoutMinutes) minuti di inattivita'." $true
        }
    }
})
$script:ImportSessionTimer.Start()

$Window.Add_Closing({
    param($Sender, $EventArgs)
    if (Test-OperationActive) {
        $EventArgs.Cancel = $true
        [System.Windows.MessageBox]::Show(
            "Attendere il completamento dell'operazione '$($script:OperationalState.Name)'. La chiusura e' bloccata per non interrompere un esito remoto potenzialmente incerto.",
            "Operazione in corso",
            "OK",
            "Warning"
        ) | Out-Null
        return
    }
    $script:OperationalState.Mode = "Closing"
    Update-OperationalControlState
    $script:ClosingApplication = $true
    foreach ($Row in $script:AllReviewRows) {
        $Row.SecretValue = ""
        $Row.SecretCachedFromSource = $false
    }
    $script:ImportSecretOverrides = @{}
    $script:ReviewFilePasswords = @{}
    $script:ImportSourceFilePasswords = @{}
    $script:RecoverySecretOverrides = @{}
    $script:RecoverySourceFilePasswords = @{}
    $script:RecoveryCandidates = @()
    if ($null -ne $script:OperationPollTimer) { $script:OperationPollTimer.Stop() }
    if ($null -ne $script:ImportSessionTimer) { $script:ImportSessionTimer.Stop() }
    Stop-ImportSession "" $false
})

Update-DestinationControlState
Update-ImportSessionState
Update-SourceMappingProfileState
Add-Activity "Applicazione pronta. Nessun documento $([char]0x00E8) stato letto."
Update-ConfigurationState

if ($RenderPreviewPath) {
    $PreviewFullPath = [IO.Path]::GetFullPath($RenderPreviewPath)
    $PreviewDirectory = [IO.Path]::GetDirectoryName($PreviewFullPath)
    if (-not $PreviewDirectory -or -not (Test-Path -LiteralPath $PreviewDirectory -PathType Container)) {
        throw "La cartella di destinazione dell'anteprima UI non esiste."
    }
    $PreviewWidth = $RenderPreviewWidth
    $PreviewHeight = $RenderPreviewHeight
    $PreviewPixelWidth = [int][math]::Ceiling($PreviewWidth * $RenderPreviewDpi / 96.0)
    $PreviewPixelHeight = [int][math]::Ceiling($PreviewHeight * $RenderPreviewDpi / 96.0)
    Show-Page $RenderPreviewPage
    if ($RenderPreviewPage -eq "Import") {
        Show-Phase04Workspace $RenderPreviewImportTab -SkipRefresh
        if ($RenderPreviewImportState -eq "populated") {
            $PassboltUrl.Text = "https://passbolt.example.test"
            $ConnectionDot.Fill = Get-Brush "#196C2E"
            $ConnectionStatus.Text = "Server verificato e fingerprint confermata"
            $DetectedFingerprint.Text = "Fingerprint: 0123456789ABCDEF0123456789ABCDEF01234567"
            $PrivateKeyPath.Text = "C:\Synthetic\operator-private.asc"
            $ImportSessionButton.Content = "Chiudi sessione"
            $ImportMetricSelected.Text = "24"
            $ImportMetricCreate.Text = "21"
            $ImportMetricDuplicates.Text = "3"
            $ImportMetricExisting.Text = "6"
            $ImportIdentity.Text = "Sessione sintetica attiva: operatore@example.test | GPGAuth verificato"
            $ImportPlanGrid.ItemsSource = @(
                [pscustomobject]@{ ActionLabel = "Crea risorsa"; Destination = "Clienti / Alfa"; Title = "Portale"; Username = "admin"; Uri = "https://portal.example.test" },
                [pscustomobject]@{ ActionLabel = "Salta duplicato"; Destination = "Clienti / Beta"; Title = "VPN"; Username = "operator"; Uri = "vpn.example.test" }
            )
            $ImportPlanStatus.Text = "Piano sintetico: 21 risorse da creare, 3 duplicati esatti; nessuna scrittura inviata."
            $ConfirmationHint.Text = "Dry-run valido. Digita IMPORTA 21 per autorizzare la scrittura."
            $RecoveryBatchesGrid.ItemsSource = @(
                [pscustomobject]@{ StatusLabel = "Recuperabile"; RecordedAtLabel = "27/08/2026 09:30"; CandidateCountLabel = "12"; BatchId = "00000000-0000-4000-8000-000000000001" }
            )
            $RecoveryStatus.Text = "Lotto associato ai 12 candidati riletti dalla cartella sorgente corrente."
            $RecoveryMetricVerified.Text = "12"
            $RecoveryMetricRemoteSuccess.Text = "8"
            $RecoveryMetricNotApplied.Text = "4"
            $RecoveryMetricConflicts.Text = "0"
            $RecoveryConfirmationHint.Text = "Verifica remota completata; conferma richiesta prima del recupero."
            $AclObjectsGrid.ItemsSource = @(
                [pscustomobject]@{ ObjectTypeLabel = "Cartella"; Path = "Clienti / Alfa"; CurrentAccessLabel = "Proprietario"; SharingLabel = "Condivisa"; StatusLabel = "Verificata" },
                [pscustomobject]@{ ObjectTypeLabel = "Risorsa"; Path = "Clienti / Alfa / Portale"; CurrentAccessLabel = "Proprietario"; SharingLabel = "Condivisa"; StatusLabel = "Verificata" }
            )
            $AclObjectSummary.Text = "Cartella: Clienti / Alfa | accesso Proprietario | ACL completa e verificata."
            $AclPermissionsGrid.ItemsSource = @(
                [pscustomobject]@{ SubjectType = "Utente"; DisplayName = "Operatore test"; PermissionLabel = "Proprietario"; VerificationLabel = "Verificata"; RecipientCount = "1" }
            )
            $AclViewerStatus.Text = "Sola lettura: 2 oggetti; ACL verificate: 2; nessuna richiesta di scrittura inviata."
        }
    }
    $PreviewRoot = [System.Windows.FrameworkElement]$Window.Content
    $PreviewRoot.Measure([System.Windows.Size]::new($PreviewWidth, $PreviewHeight))
    $PreviewRoot.Arrange([System.Windows.Rect]::new(0, 0, $PreviewWidth, $PreviewHeight))
    $PreviewRoot.UpdateLayout()
    $Phase04ActionBottoms = [ordered]@{}
    if ($RenderPreviewPage -eq "Import") {
        $PreviewActionControls = @(
            [pscustomobject]@{ Workspace = "new_import"; Name = "new_import"; Control = $ExecuteImportButton },
            [pscustomobject]@{ Workspace = "recovery"; Name = "recovery"; Control = $ExecuteRecoveryButton },
            [pscustomobject]@{ Workspace = "existing_acl"; Name = "existing_acl"; Control = $ManageAclJournalsButton }
        )
        foreach ($PreviewAction in $PreviewActionControls) {
            Show-Phase04Workspace $PreviewAction.Workspace -SkipRefresh
            $PreviewRoot.UpdateLayout()
            $ActionBottom = $PreviewAction.Control.TranslatePoint(
                [System.Windows.Point]::new(0, $PreviewAction.Control.ActualHeight),
                $PreviewRoot
            ).Y
            $Phase04ActionBottoms[$PreviewAction.Name] = [math]::Round($ActionBottom, 1)
            if ($ActionBottom -gt ($PreviewRoot.ActualHeight + 0.5)) {
                throw "Il comando della fase 04 '$($PreviewAction.Name)' supera il bordo inferiore dell'anteprima."
            }
        }
        Show-Phase04Workspace $RenderPreviewImportTab -SkipRefresh
        $PreviewRoot.UpdateLayout()
    }
    $PreviewBitmap = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(
        $PreviewPixelWidth,
        $PreviewPixelHeight,
        $RenderPreviewDpi,
        $RenderPreviewDpi,
        [System.Windows.Media.PixelFormats]::Pbgra32
    )
    $PreviewBitmap.Render($PreviewRoot)
    $PreviewEncoder = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
    $PreviewEncoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($PreviewBitmap))
    $PreviewStream = [IO.File]::Open($PreviewFullPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $PreviewEncoder.Save($PreviewStream)
    } finally {
        $PreviewStream.Dispose()
    }
    [pscustomobject]@{
        app = "Passbolt Migration Assistant"
        version = "0.29.0-beta.1"
        preview = $PreviewFullPath
        page = $RenderPreviewPage
        import_tab = if ($RenderPreviewPage -eq "Import") { $RenderPreviewImportTab } else { $null }
        import_state = if ($RenderPreviewPage -eq "Import") { $RenderPreviewImportState } else { $null }
        width = $PreviewWidth
        height = $PreviewHeight
        pixel_width = $PreviewPixelWidth
        pixel_height = $PreviewPixelHeight
        dpi = $RenderPreviewDpi
        layout = [pscustomobject]@{
            root_width = [math]::Round($PreviewRoot.ActualWidth, 1)
            root_height = [math]::Round($PreviewRoot.ActualHeight, 1)
            files_grid_width = [math]::Round($FilesGrid.ActualWidth, 1)
            files_columns = @($FilesGrid.Columns | ForEach-Object { [math]::Round($_.ActualWidth, 1) })
            review_grid_width = [math]::Round($ReviewCandidatesGrid.ActualWidth, 1)
            review_columns = @($ReviewCandidatesGrid.Columns | ForEach-Object { [math]::Round($_.ActualWidth, 1) })
            import_page_width = [math]::Round($ImportPage.ActualWidth, 1)
            import_page_height = [math]::Round($ImportPage.ActualHeight, 1)
            import_page_top = [math]::Round($ImportPage.TranslatePoint([System.Windows.Point]::new(0, 0), $PreviewRoot).Y, 1)
            active_step_top = [math]::Round($StepImport.TranslatePoint([System.Windows.Point]::new(0, 0), $PreviewRoot).Y, 1)
            phase04_action_bottoms = $Phase04ActionBottoms
        }
        status = "OK"
    } | ConvertTo-Json
    $Window.Close()
    exit 0
}

if ($SelfTest) {
    $SourceText = [IO.File]::ReadAllText($PSCommandPath)
    $ForbiddenPumpName = "Do" + "Events"
    if ($SourceText -match ("System\.Windows\.Forms\.Application.*" + $ForbiddenPumpName + "|\b" + $ForbiddenPumpName + "\s*\(")) {
        throw "Il quality gate operativo vieta il pumping manuale degli eventi."
    }
    $SyntheticOperationId = Enter-OperationalState "Transizione sintetica" "verify" "synthetic-operation"
    if (
        $SyntheticOperationId -ne "synthetic-operation" -or
        -not (Test-OperationActive) -or
        [string]$script:OperationalState.Category -ne "verify" -or
        $Window.Content.IsEnabled
    ) {
        throw "La transizione sintetica Idle -> Running non e' coerente."
    }
    if ($null -ne (Enter-OperationalState "Reentrancy sintetica" "write" "synthetic-reentrant")) {
        throw "Il modello operativo ha consentito una seconda operazione attiva."
    }
    if (Exit-OperationalState "synthetic-stale") {
        throw "Una chiusura con identificatore non corrente ha modificato lo stato operativo."
    }
    if (-not (Test-OperationActive) -or -not (Exit-OperationalState $SyntheticOperationId)) {
        throw "La transizione sintetica Running -> Idle non e' coerente."
    }
    if ((Test-OperationActive) -or [string]$script:OperationalState.Mode -ne "Idle" -or -not $Window.Content.IsEnabled) {
        throw "Lo stato operativo sintetico non ha ripristinato l'interfaccia."
    }
    $script:SyntheticProgressOrder = New-Object System.Collections.Generic.List[int]
    $SyntheticProgressQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    foreach ($Sequence in @(1, 2, 3)) { $SyntheticProgressQueue.Enqueue([pscustomobject]@{ sequence = $Sequence }) }
    $SyntheticProgressOperation = [pscustomobject]@{
        ProgressQueue = $SyntheticProgressQueue
        OnProgress = {
            param($Envelope, $Operation)
            [void]$script:SyntheticProgressOrder.Add([int]$Envelope.sequence)
        }
    }
    Drain-OperationProgress $SyntheticProgressOperation
    if (($script:SyntheticProgressOrder -join ',') -ne '1,2,3' -or $SyntheticProgressQueue.Count -ne 0) {
        throw "La coda progressi sintetica non preserva l'ordine FIFO."
    }
    $script:SyntheticProgressOrder = $null
    $script:SyntheticAsyncWorkerResult = $null
    $script:SyntheticAsyncWorkerFailure = ""
    $SyntheticWorkerParameters = @{
        Name = "Worker sintetico"
        Category = "read"
        WorkKind = "PythonJson"
        Payload = New-PythonJsonOperationPayload $InventoryScript @("--self-test") 60000
        OnSuccess = {
            param($Result, $Operation)
            $script:SyntheticAsyncWorkerResult = $Result
        }
        OnFailure = {
            param($FailureMessage, $Operation)
            $script:SyntheticAsyncWorkerFailure = $FailureMessage
        }
    }
    if (-not (Start-UiOperation @SyntheticWorkerParameters)) {
        throw "Il worker sintetico non e' stato avviato."
    }
    $SyntheticWorkerOperation = $script:OperationalState.Active
    if (-not $SyntheticWorkerOperation.AsyncResult.AsyncWaitHandle.WaitOne(120000)) {
        try { $SyntheticWorkerOperation.PowerShell.Stop() } catch {}
        $SyntheticWorkerOperation.PowerShell.Dispose()
        [void](Exit-OperationalState ([string]$SyntheticWorkerOperation.OperationId))
        throw "Il worker sintetico non ha rispettato il timeout."
    }
    Complete-UiOperation ([string]$SyntheticWorkerOperation.OperationId)
    if (
        $script:SyntheticAsyncWorkerFailure -or
        $null -eq $script:SyntheticAsyncWorkerResult -or
        [int]$script:SyntheticAsyncWorkerResult.supported_extensions -ne 16 -or
        (Test-OperationActive) -or
        -not $Window.Content.IsEnabled
    ) {
        throw "Il worker asincrono sintetico non ha completato il ciclo operativo. $($script:SyntheticAsyncWorkerFailure)"
    }
    $script:SyntheticAsyncWorkerResult = $null
    $SourceText = $null
    $CompatibilityList = New-Object System.Collections.Generic.List[object]
    $CompatibilityList.Add([pscustomobject]@{ value = 1 })
    $CompatibilityArray = $CompatibilityList.ToArray()
    if ($CompatibilityArray.Count -ne 1) {
        throw "Verifica compatibilit$([char]0x00E0) collezioni Windows PowerShell non riuscita."
    }
    $NestedTabFound = $false
    foreach ($TabControl in @($ImportWorkspaceTabs, $AclDetailTabs)) {
        $Ancestor = $TabControl.Parent
        while ($null -ne $Ancestor) {
            if ($Ancestor -is [System.Windows.Controls.TabControl]) { $NestedTabFound = $true; break }
            $Ancestor = $Ancestor.Parent
        }
    }
    if (
        $Window.Title -notmatch "v0\.29\.0-beta\.1" -or
        $Window.MinWidth -lt 1160 -or
        $Window.MinHeight -lt 740 -or
        [string]$Window.FontFamily -notmatch "Segoe UI Variable" -or
        $VerifyButton.MinHeight -lt 34 -or
        $null -eq $StepConfiguration.Template -or
        $FilesGrid.RowHeight -lt 40 -or
        $FilesGrid.Columns[1].MinWidth -lt 300 -or
        $FilesGrid.HorizontalScrollBarVisibility -ne [System.Windows.Controls.ScrollBarVisibility]::Auto -or
        $ReviewCandidatesGrid.HorizontalScrollBarVisibility -ne [System.Windows.Controls.ScrollBarVisibility]::Auto -or
        $null -eq $ClientFolder.Template -or
        $null -eq $DestinationMode.Template -or
        $null -eq $ReviewPasswordToggle.Template -or
        $null -eq $ImportWorkspaceTabs.Template -or
        $NestedTabFound -or
        $MigrationWorkspace.Parent -is [System.Windows.Controls.ScrollViewer] -or
        [System.Windows.Controls.Grid]::GetRow($MigrationWorkspace.Parent) -ne 2
    ) {
        throw "Il design system moderno non rispetta il contratto visivo WPF."
    }
    $Phase04KeyboardControls = @(
        $AclWorkspaceButton,
        $PassboltUrl,
        $VerifyButton,
        $PrivateKeyPath,
        $BrowseKeyButton,
        $KeyPassphrase,
        $MfaTotpCode,
        $ImportSessionButton,
        $DestinationMode,
        $DestinationFolder,
        $ResourceFormat,
        $ConfigurePermissionsButton,
        $DryRunButton,
        $NewImportModeButton,
        $RecoveryModeButton,
        $ImportBackButton,
        $ImportConfirmation,
        $ExecuteImportButton,
        $RefreshRecoveryButton,
        $ArchiveRecoveryButton,
        $RecoveryBackButton,
        $RecoveryConfirmation,
        $VerifyRecoveryButton,
        $ExecuteRecoveryButton,
        $RefreshAclButton,
        $AclTypeFilter,
        $AclSearchBox,
        $AclPlanButton,
        $AclConfirmation,
        $ApplyAclButton,
        $RecoverAclButton,
        $ManageAclJournalsButton,
        $AclBackButton
    )
    $Phase04KeyboardBlocked = @($Phase04KeyboardControls | Where-Object {
        $null -eq $_ -or -not $_.Focusable -or -not $_.IsTabStop
    })
    $FocusTriggerCount = [regex]::Matches($Xaml.OuterXml, 'Property="IsKeyboardFocus(?:ed|Within)"').Count
    $Phase04NamedInputs = @(
        $PassboltUrl,
        $PrivateKeyPath,
        $KeyPassphrase,
        $MfaTotpCode,
        $DestinationMode,
        $DestinationFolder,
        $ResourceFormat,
        $ImportConfirmation,
        $RecoveryConfirmation,
        $AclTypeFilter,
        $AclSearchBox,
        $AclConfirmation
    )
    $Phase04UnnamedInputs = @($Phase04NamedInputs | Where-Object {
        [string]::IsNullOrWhiteSpace([System.Windows.Automation.AutomationProperties]::GetName($_))
    })
    if ($Phase04KeyboardBlocked.Count -gt 0 -or $FocusTriggerCount -lt 9 -or $Phase04UnnamedInputs.Count -gt 0) {
        throw "La fase 04 non espone un percorso di tastiera completo con focus visibile."
    }
    $Phase0103NamedInputs = @(
        $ClientFolder,
        $ClientFilter,
        $FormatFilter,
        $SearchBox,
        $FilesGrid,
        $ActivityLog,
        $ReviewStatusFilter,
        $ReviewSearchBox,
        $ReviewCandidatesGrid
    )
    if (@($Phase0103NamedInputs | Where-Object {
        [string]::IsNullOrWhiteSpace([System.Windows.Automation.AutomationProperties]::GetName($_))
    }).Count -gt 0) {
        throw "Le fasi 01-03 contengono input critici senza nome accessibile coerente."
    }
    $ClientFolder.Text = $ProjectRoot
    $script:ConnectionVerified = $false
    Update-ConfigurationState
    if (-not $ContinueButton.IsEnabled -or -not $StepInventory.IsEnabled -or $VerifyButton.IsEnabled) {
        throw "La preparazione locale deve consentire l'inventario senza una connessione Passbolt verificata."
    }
    $PlannedPassboltUrl.Text = "https://passbolt.example.test"
    $script:InventoryFolder = $ProjectRoot
    $script:InventoryResult = [pscustomobject]@{ synthetic = $true }
    $script:ReviewResult = [pscustomobject]@{ synthetic = $true }
    Update-ConfigurationState
    if (-not $SaveInventoryProjectButton.IsEnabled -or -not $SaveReviewProjectButton.IsEnabled -or $script:ConnectionVerified) {
        throw "Il progetto di preparazione locale deve poter essere salvato senza attribuire fiducia al server."
    }
    $PlannedPassboltUrl.Text = ""
    $script:InventoryFolder = ""
    $script:InventoryResult = $null
    $script:ReviewResult = $null
    $ClientFolder.Text = ""
    Update-ConfigurationState
    $ArgumentProbeValue = "C:\Cartella Con Spazi\"
    $ArgumentProbeCode = "import json,sys; print(json.dumps({'ok': True, 'result': {'argument': sys.argv[1]}}))"
    $ArgumentProbe = Invoke-SecureJsonProcess $PythonExecutable @("-c", $ArgumentProbeCode, $ArgumentProbeValue) ([pscustomobject]@{ test = $true }) 30000
    if (-not $ArgumentProbe.ok -or $ArgumentProbe.result.argument -ne $ArgumentProbeValue) {
        throw "Verifica degli argomenti di processo con spazi non riuscita."
    }
    $SessionProbeCode = @'
import json
import sys

for line in sys.stdin:
    request = json.loads(line.lstrip("\ufeff"))
    if request.get("command") == "session-progress-probe":
        print(json.dumps({"type": "progress", "batch_id": "11111111-1111-4111-8111-111111111111", "event_type": "duplicate_skipped", "payload": {"candidate_id": "aaaaaaaaaaaaaaaa", "duplicate_kind": "batch"}}), flush=True)
    print(json.dumps({"ok": True, "result": {"command": request.get("command"), "session_id": request.get("session_id")}}), flush=True)
    if request.get("command") == "session-close":
        break
'@
    $SessionProbePath = Join-Path ([IO.Path]::GetTempPath()) ("passbolt-session-transport-" + [guid]::NewGuid().ToString("N") + ".py")
    [IO.File]::WriteAllText(
        $SessionProbePath,
        $SessionProbeCode,
        (New-Object System.Text.UTF8Encoding($false))
    )
    $SessionProbeStartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $SessionProbeStartInfo.FileName = $PythonExecutable
    $SessionProbeStartInfo.Arguments = (@("-u", $SessionProbePath) | ForEach-Object { ConvertTo-ProcessArgument ([string]$_) }) -join ' '
    $SessionProbeStartInfo.UseShellExecute = $false
    $SessionProbeStartInfo.CreateNoWindow = $true
    $SessionProbeStartInfo.RedirectStandardInput = $true
    $SessionProbeStartInfo.RedirectStandardOutput = $true
    $SessionProbeStartInfo.RedirectStandardError = $true
    $SessionProbeStartInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $SessionProbeStartInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    $SessionProbeProcess = New-Object System.Diagnostics.Process
    $SessionProbeProcess.StartInfo = $SessionProbeStartInfo
    try {
        if (-not $SessionProbeProcess.Start()) { throw "Impossibile avviare il test del protocollo persistente." }
        $script:ImportSessionProcess = $SessionProbeProcess
        $script:ImportSessionErrorTask = $SessionProbeProcess.StandardError.ReadToEndAsync()
        $script:ImportSessionId = "transport-probe"
        try {
            $SessionProbeEnvelope = Invoke-ImportSessionJson ([pscustomobject]@{ command = "session-readiness"; session_id = "transport-probe" }) 30000
        } catch {
            $ProbeExitCode = "non disponibile"
            try {
                if ($SessionProbeProcess.HasExited) { $ProbeExitCode = [string]$SessionProbeProcess.ExitCode }
            } catch {}
            $ProbeErrorOutput = ""
            try {
                if ($null -ne $script:ImportSessionErrorTask -and $script:ImportSessionErrorTask.Wait(5000)) {
                    $ProbeErrorOutput = [string]$script:ImportSessionErrorTask.Result
                }
            } catch {}
            $ProbeErrorOutput = ($ProbeErrorOutput -replace '\s+', ' ').Trim()
            if ([string]::IsNullOrWhiteSpace($ProbeErrorOutput)) { $ProbeErrorOutput = "nessun dettaglio" }
            if ($ProbeErrorOutput.Length -gt 1000) { $ProbeErrorOutput = $ProbeErrorOutput.Substring(0, 1000) }
            throw "Il test sintetico del trasporto persistente non e' riuscito (Python: $PythonExecutable; codice: $ProbeExitCode; stderr: $ProbeErrorOutput)."
        }
        if (-not $SessionProbeEnvelope.ok -or $SessionProbeEnvelope.result.command -ne "session-readiness" -or $SessionProbeEnvelope.result.session_id -ne "transport-probe") {
            throw "Il protocollo persistente dell'interfaccia non ha restituito la risposta prevista."
        }
        $script:ProgressProbeCount = 0
        $script:AsyncSessionProbeEnvelope = $null
        $script:AsyncSessionProbeFailure = ""
        $AsyncSessionProbeParameters = @{
            Name = "Trasporto persistente asincrono sintetico"
            Category = "verify"
            WorkKind = "ImportSessionJson"
            Payload = New-ImportSessionOperationPayload ([pscustomobject]@{ command = "session-progress-probe"; session_id = "transport-probe" }) 30000
            OnProgress = {
                param($ProgressEnvelope, $Operation)
                if ([string]$ProgressEnvelope.event_type -eq "duplicate_skipped") { $script:ProgressProbeCount = 1 }
            }
            OnSuccess = {
                param($Envelope, $Operation)
                $script:AsyncSessionProbeEnvelope = $Envelope
            }
            OnFailure = {
                param($FailureMessage, $Operation)
                $script:AsyncSessionProbeFailure = $FailureMessage
            }
        }
        if (-not (Start-UiOperation @AsyncSessionProbeParameters)) { throw "Il test asincrono del trasporto persistente non e' stato avviato." }
        $AsyncSessionProbeOperation = $script:OperationalState.Active
        if (-not $AsyncSessionProbeOperation.AsyncResult.AsyncWaitHandle.WaitOne(60000)) {
            try { $AsyncSessionProbeOperation.PowerShell.Stop() } catch {}
            $AsyncSessionProbeOperation.PowerShell.Dispose()
            [void](Exit-OperationalState ([string]$AsyncSessionProbeOperation.OperationId))
            throw "Timeout del test asincrono del trasporto persistente."
        }
        Complete-UiOperation ([string]$AsyncSessionProbeOperation.OperationId)
        if ($script:AsyncSessionProbeFailure -or -not [bool]$script:AsyncSessionProbeEnvelope.ok -or [int]$script:ProgressProbeCount -ne 1) {
            throw "Il trasporto persistente asincrono non inoltra gli eventi live della dashboard. $($script:AsyncSessionProbeFailure)"
        }
        Close-ImportSessionAsync "" $false
        $AsyncCloseProbeOperation = $script:OperationalState.Active
        if ($null -eq $AsyncCloseProbeOperation -or -not $AsyncCloseProbeOperation.AsyncResult.AsyncWaitHandle.WaitOne(30000)) {
            throw "La chiusura asincrona della sessione sintetica non ha rispettato il timeout."
        }
        Complete-UiOperation ([string]$AsyncCloseProbeOperation.OperationId)
        if ((Test-OperationActive) -or $null -ne $script:ImportSessionProcess -or $script:ImportSessionId) {
            throw "La chiusura asincrona della sessione sintetica non ha ripulito il coordinatore."
        }
        Remove-Variable -Scope Script -Name ProgressProbeCount -ErrorAction SilentlyContinue
        Remove-Variable -Scope Script -Name AsyncSessionProbeEnvelope -ErrorAction SilentlyContinue
        Remove-Variable -Scope Script -Name AsyncSessionProbeFailure -ErrorAction SilentlyContinue
    } finally {
        Stop-ImportSession "" $false
        if (Test-Path -LiteralPath $SessionProbePath -PathType Leaf) {
            Remove-Item -LiteralPath $SessionProbePath -Force
        }
    }
    $script:ImportSessionProcess = [System.Diagnostics.Process]::GetCurrentProcess()
    $script:ImportSessionId = "uncertain-import-guard-probe"
    $script:InventoryFolder = "C:\synthetic-import-root"
    $script:ImportSessionRoot = $script:InventoryFolder
    $script:ConnectionVerified = $true
    $script:ImportCandidates = @([pscustomobject]@{ candidate_id = "uncertain-import-probe" })
    $script:RecoveryPlan = $null
    $script:ImportRecoveryRequired = $false
    Update-ImportSessionState
    if (-not $DryRunButton.IsEnabled -or -not $NewImportModeButton.IsEnabled) {
        throw "Il probe della guardia import non raggiunge lo stato pronto iniziale."
    }
    $script:ImportRecoveryRequired = $true
    Update-ImportSessionState
    if ($DryRunButton.IsEnabled -or $NewImportModeButton.IsEnabled -or [string]$DryRunButton.ToolTip -notmatch "Recupero obbligatorio") {
        throw "Un esito import incerto non blocca retry e nuova preparazione a favore del recupero."
    }
    $script:ImportRecoveryRequired = $false
    $script:ImportSessionProcess = $null
    $script:ImportSessionId = ""
    $script:InventoryFolder = ""
    $script:ImportSessionRoot = ""
    $script:ConnectionVerified = $false
    $script:ImportCandidates = @()
    Update-ImportSessionState
    $ReviewBackendTest = Invoke-PythonJson $ReviewScript @("--self-test")
    if ($ReviewBackendTest.secrets_serialized -or -not $ReviewBackendTest.excel_password_prompt_supported -or -not $ReviewBackendTest.unlimited_file_selection -or -not $ReviewBackendTest.unlimited_candidate_collection -or -not $ReviewBackendTest.single_pass_field_detection -or -not $ReviewBackendTest.source_mapping_profiles) {
        throw "Il backend di revisione non rispetta il contratto di mascheramento."
    }
    $ReceiptBackendTest = Invoke-PythonJson $ReceiptScript @("--self-test")
    if (-not $ReceiptBackendTest.ok -or $ReceiptBackendTest.result.compatibility_profile -ne "passbolt-v4-v5-resource-preview" -or -not $ReceiptBackendTest.result.closed_schema -or -not $ReceiptBackendTest.result.atomic_write) {
        throw "Il backend delle ricevute non rispetta il contratto locale chiuso."
    }
    $SourceFeedbackProbe = Invoke-SecureJsonProcess $PythonExecutable @($ReceiptScript, "--secure-json") ([pscustomobject][ordered]@{
        command = "source-summary"
        inventory = [pscustomobject][ordered]@{
            supported_files = 3
            ignored_files = 1
            issues = @([pscustomobject][ordered]@{ reason_code = "unsupported_format"; extension = ".bak"; count = 1 })
        }
        review = [pscustomobject][ordered]@{
            selected_files = 2
            analyzed_files = 2
            candidate_count = 1
            ready_count = 1
            incomplete_count = 0
            issues = @([pscustomobject][ordered]@{ reason_code = "no_candidate"; extension = ".txt"; count = 1 })
        }
    }) 30000
    if (-not $SourceFeedbackProbe.ok -or [bool]$SourceFeedbackProbe.result.contains_source_identifiers -or [int]$SourceFeedbackProbe.result.issue_occurrences -ne 2) {
        throw "Il riepilogo sorgenti non conserva soltanto conteggi aggregati."
    }
    $script:ImportCandidates = @([pscustomobject]@{ candidate_id = "receipt-a" }, [pscustomobject]@{ candidate_id = "receipt-b" })
    $ReceiptPlanProbe = [pscustomobject]@{
        plan_digest = ("a" * 64)
        preflight_status = "passed"
        destination_mode = "client_folders"
        resource_format_selected = "v4"
        folder_format_selected = "v4"
        permission_mode = "inherited"
        permission_template_entry_count = 0
        create_count = 2
        duplicate_count = 0
        blocked_count = 0
        create_folder_count = 1
        create_shared_folder_count = 0
        reconcile_shared_folder_count = 0
        reuse_folder_count = 0
        shared_create_count = 0
        encrypted_secret_copy_count = 2
        required_clients = @("cliente-a")
        client_destination_mapping = @()
        preflight_checks = @(
            [pscustomobject]@{ id = "authenticated_identity"; status = "passed" },
            [pscustomobject]@{ id = "conflicts"; status = "passed" }
        )
    }
    $ReceiptEvidenceProbe = New-PreflightReceiptEvidence $ReceiptPlanProbe
    $ReceiptProbe = Invoke-SecureJsonProcess $PythonExecutable @($ReceiptScript, "--secure-json") ([pscustomobject][ordered]@{
        command = "build-receipt"
        receipt_type = "preflight"
        evidence = $ReceiptEvidenceProbe
    }) 30000
    $ReceiptProbeText = $ReceiptProbe | ConvertTo-Json -Depth 12 -Compress
    if (-not $ReceiptProbe.ok -or [string]$ReceiptProbe.result.receipt_type -ne "preflight" -or [string]$ReceiptProbe.result.formats.resource -ne "v4" -or $ReceiptProbeText -match 'password|passphrase|fingerprint|session_id|username|candidate_id|resource_id|folder_id') {
        throw "La ricevuta preflight sintetica contiene campi non ammessi."
    }
    $script:ImportCandidates = @()
    $LocalProjectBackendTest = Invoke-PythonJson $LocalProjectScript @("--self-test")
    if (
        $LocalProjectBackendTest.version -ne "0.29.0-beta.1" -or
        -not $LocalProjectBackendTest.dpapi_current_user_required -or
        $LocalProjectBackendTest.secret_fields_serialized -or
        $LocalProjectBackendTest.trusted_fingerprint_persisted -or
        $LocalProjectBackendTest.session_state_persisted -or
        -not $LocalProjectBackendTest.strict_envelope
    ) {
        throw "Il backend dei progetti locali non rispetta il contratto di sicurezza."
    }
    $LocalProjectPlainProbe = '{"kind":"synthetic-local-project","contains_secrets":false}'
    $LocalProjectCipherProbe = $null
    $LocalProjectRoundTripProbe = $null
    $LocalProjectDpapiProbeAvailable = $false
    try {
        $LocalProjectCipherProbe = Protect-LocalProjectText $LocalProjectPlainProbe
        $LocalProjectRoundTripProbe = Unprotect-LocalProjectText $LocalProjectCipherProbe
        $LocalProjectDpapiProbeAvailable = $true
        if (
            $LocalProjectRoundTripProbe -cne $LocalProjectPlainProbe -or
            [Convert]::ToBase64String($LocalProjectCipherProbe).Contains("synthetic-local-project") -or
            $null -eq $OpenProjectButton -or
            $null -eq $SaveInventoryProjectButton -or
            $null -eq $SaveReviewProjectButton -or
            $SaveInventoryProjectButton.IsEnabled -or
            $SaveReviewProjectButton.IsEnabled
        ) {
            throw "La protezione DPAPI o i controlli UI dei progetti locali non sono nello stato previsto."
        }
    } catch [System.Security.Cryptography.CryptographicException] {
        # Some CI/sandbox hosts launch PowerShell under an impersonated token
        # without a loaded user profile. Runtime save/load still fails closed;
        # regular desktop and hosted Windows CI exercise the round-trip when
        # CurrentUser DPAPI is available.
        $LocalProjectDpapiProbeAvailable = $false
    } finally {
        if ($null -ne $LocalProjectCipherProbe) { [Array]::Clear($LocalProjectCipherProbe, 0, $LocalProjectCipherProbe.Length) }
        $LocalProjectPlainProbe = $null
        $LocalProjectRoundTripProbe = $null
    }
    if ($null -eq $OpenProjectButton -or $null -eq $SaveInventoryProjectButton -or $null -eq $SaveReviewProjectButton -or $SaveInventoryProjectButton.IsEnabled -or $SaveReviewProjectButton.IsEnabled) {
        throw "I controlli UI dei progetti locali non sono nello stato fail-closed previsto."
    }
    if ([Environment]::GetEnvironmentVariable("PASSBOLT_MIGRATION_CI") -and -not $LocalProjectDpapiProbeAvailable) {
        throw "DPAPI CurrentUser non e' disponibile nel quality gate CI."
    }
    $LocalProjectWriteProbePath = Join-Path ([IO.Path]::GetTempPath()) ("passbolt-local-project-write-" + [guid]::NewGuid().ToString("N") + ".pbproj")
    try {
        Write-AtomicUtf8File $LocalProjectWriteProbePath '{"probe":1}'
        Write-AtomicUtf8File $LocalProjectWriteProbePath '{"probe":2}'
        if ([IO.File]::ReadAllText($LocalProjectWriteProbePath) -cne '{"probe":2}') {
            throw "La scrittura atomica dei progetti locali non conserva l'ultima versione completa."
        }
    } finally {
        if (Test-Path -LiteralPath $LocalProjectWriteProbePath -PathType Leaf) {
            Remove-Item -LiteralPath $LocalProjectWriteProbePath -Force
        }
    }
    $ProjectInventoryRowA = [pscustomobject]@{ RelativePath = "Cliente Alfa/accessi.csv" }
    $ProjectInventoryRowB = [pscustomobject]@{ RelativePath = "Cliente Beta/server.txt" }
    $script:AllInventoryRows = @($ProjectInventoryRowA, $ProjectInventoryRowB)
    $FilesGrid.ItemsSource = $script:AllInventoryRows
    $script:PendingProjectSelectedFiles = @("Cliente Beta/server.txt")
    Apply-PendingProjectInventorySelection
    if ($FilesGrid.SelectedItems.Count -ne 1 -or [string]$FilesGrid.SelectedItem.RelativePath -ne "Cliente Beta/server.txt") {
        throw "Il ripristino del progetto non ricostruisce la selezione inventario prevista."
    }
    $ProjectCandidateRowA = [pscustomobject]@{ CandidateId = ("a" * 64); SourceHash = ("b" * 64); Status = "ready" }
    $ProjectCandidateRowB = [pscustomobject]@{ CandidateId = ("c" * 64); SourceHash = ("d" * 64); Status = "ready" }
    $script:AllReviewRows = @($ProjectCandidateRowA, $ProjectCandidateRowB)
    $ReviewCandidatesGrid.ItemsSource = $script:AllReviewRows
    $script:PendingProjectSelectedCandidates = @([pscustomobject]@{ candidate_id = ("c" * 64); source_sha256 = ("d" * 64) })
    Apply-PendingProjectCandidateSelection
    if ($ReviewCandidatesGrid.SelectedItems.Count -ne 1 -or [string]$ReviewCandidatesGrid.SelectedItem.CandidateId -ne ("c" * 64)) {
        throw "Il ripristino del progetto non lega la selezione candidato alle prove tecniche previste."
    }
    $FilesGrid.UnselectAll()
    $ReviewCandidatesGrid.UnselectAll()
    $FilesGrid.ItemsSource = $null
    $ReviewCandidatesGrid.ItemsSource = $null
    $script:AllInventoryRows = @()
    $script:AllReviewRows = @()
    $ImportBackendTest = Invoke-PythonJson $ImportScript @("--self-test")
    if (-not $ImportBackendTest.ok -or $ImportBackendTest.result.compatibility_profile -ne "passbolt-v4-v5-resource-preview" -or -not $ImportBackendTest.result.v5_resource_format_supported -or -not $ImportBackendTest.result.v5_folder_format_rejected -or -not $ImportBackendTest.result.automatic_format_rejected -or $ImportBackendTest.result.secrets_serialized -or -not $ImportBackendTest.result.unlimited_candidate_selection -or -not $ImportBackendTest.result.indexed_candidate_revalidation -or -not $ImportBackendTest.result.early_parser_stop -or -not $ImportBackendTest.result.persistent_session_protocol -or -not $ImportBackendTest.result.reconciliation_progress_protocol -or -not $ImportBackendTest.result.dashboard_progress_forwarding -or -not $ImportBackendTest.result.authenticated_preflight_protocol -or -not $ImportBackendTest.result.post_import_verification_protocol -or -not $ImportBackendTest.result.authenticated_recovery_protocol -or -not $ImportBackendTest.result.recovery_management_protocol -or -not $ImportBackendTest.result.recoverable_archive_protocol -or -not $ImportBackendTest.result.explicit_reveal_supported -or -not $ImportBackendTest.result.protected_excel_integrity_supported -or -not $ImportBackendTest.result.source_mapping_profile_revalidation -or -not $ImportBackendTest.result.permission_editor_protocol -or -not $ImportBackendTest.result.existing_acl_viewer_protocol -or -not $ImportBackendTest.result.existing_acl_dry_run_protocol -or -not $ImportBackendTest.result.acl_journal_management_protocol) {
        throw "Il backend di importazione non rispetta il contratto di sicurezza."
    }
    $CryptoBackendTest = Invoke-SecureJsonProcess $NodeExecutable @($CryptoScript) ([pscustomobject]@{ command = "self-test" }) 120000
    if (-not $CryptoBackendTest.ok -or $CryptoBackendTest.result.compatibility_profile -ne "passbolt-v4-v5-resource-preview" -or -not $CryptoBackendTest.result.v5_resource_format_supported -or -not $CryptoBackendTest.result.v5_folder_format_rejected -or -not $CryptoBackendTest.result.automatic_format_rejected -or -not $CryptoBackendTest.result.v5_acl_mutation_rejected -or -not $CryptoBackendTest.result.v5_folder_payload_rejected -or -not $CryptoBackendTest.result.v5_shared_resource_payload_rejected -or $CryptoBackendTest.result.secrets_serialized -or -not $CryptoBackendTest.result.utf8_bom_input -or -not $CryptoBackendTest.result.unlimited_candidate_selection -or -not $CryptoBackendTest.result.indexed_large_batch_planning -or -not $CryptoBackendTest.result.source_mapping_digest_bound -or -not $CryptoBackendTest.result.gpgauth_bounded_clock_verification -or -not $CryptoBackendTest.result.persistent_session_protocol -or -not $CryptoBackendTest.result.reconciliation_progress_protocol -or -not $CryptoBackendTest.result.batch_dashboard_progress_protocol -or -not $CryptoBackendTest.result.authenticated_preflight_protocol -or -not $CryptoBackendTest.result.post_import_verification_protocol -or -not $CryptoBackendTest.result.authenticated_recovery_protocol -or -not $CryptoBackendTest.result.permission_editor_protocol -or -not $CryptoBackendTest.result.existing_acl_viewer_protocol -or -not $CryptoBackendTest.result.existing_acl_dry_run_protocol -or -not $CryptoBackendTest.result.official_wrapped_gpgauth_payload_contract -or -not $CryptoBackendTest.result.official_minimal_totp_payload_contract) {
        throw "Il bridge OpenPGP locale non ha superato il test di sicurezza."
    }
    $IntegrationMatrixTest = Invoke-PythonJson $IntegrationMatrixScript @("self-test")
    if (-not $IntegrationMatrixTest.ok -or $IntegrationMatrixTest.result.secrets_serialized -or -not $IntegrationMatrixTest.result.read_only_automation -or -not $IntegrationMatrixTest.result.ci_real_instance_guard -or -not $IntegrationMatrixTest.result.report_digest_valid -or -not $IntegrationMatrixTest.result.v5_release_gate_rejected -or -not $IntegrationMatrixTest.result.v5_resource_preview_report_supported -or -not $IntegrationMatrixTest.result.v5_custom_share_negative_proof_required -or -not $IntegrationMatrixTest.result.v5_custom_share_negative_proof_recorded -or -not $IntegrationMatrixTest.result.v5_manual_contract_complete -or -not $IntegrationMatrixTest.result.safe_failure_projection -or $IntegrationMatrixTest.result.automated_scenario_count -ne 7 -or $IntegrationMatrixTest.result.manual_scenario_count -ne 9) {
        throw "La matrice di integrazione non rispetta il contratto di sicurezza."
    }
    $LoginDiagnosticProbe = Get-SecureErrorMessage ([pscustomobject]@{
        error = [pscustomobject]@{
            code = "MFA_TOTP_REJECTED"
            message = "Codice non accettato."
            details = [pscustomobject]@{ auth_phase = "mfa_totp"; http_status = 400; clock_skew_seconds = 35 }
        }
    })
    if ($LoginDiagnosticProbe -notmatch "MFA_TOTP_REJECTED" -or $LoginDiagnosticProbe -notmatch "verifica MFA TOTP" -or $LoginDiagnosticProbe -notmatch "HTTP 400" -or $LoginDiagnosticProbe -notmatch "sincronizzazione") {
        throw "La diagnostica sicura del login non espone fase, codice e stato HTTP."
    }
    $GpgAuthClockProbe = Get-SecureErrorMessage ([pscustomobject]@{
        error = [pscustomobject]@{
            code = "AUTH_CHALLENGE_CLOCK_SKEW"
            message = "Orologi troppo distanti."
            details = [pscustomobject]@{ auth_phase = "challenge_decryption"; clock_skew_seconds = 301 }
        }
    })
    if ($GpgAuthClockProbe -notmatch "AUTH_CHALLENGE_CLOCK_SKEW" -or $GpgAuthClockProbe -notmatch "decifratura sfida utente" -or $GpgAuthClockProbe -notmatch "scarto orologio 301 s" -or $GpgAuthClockProbe -notmatch "server Passbolt") {
        throw "La diagnostica temporale GPGAuth non espone il suggerimento sicuro previsto."
    }
    if ([string]$ImportSessionButton.Content -ne "Avvia sessione" -or $script:ImportSessionIdleTimeoutMinutes -ne 30) {
        throw "I controlli UI della sessione autenticata non sono nello stato previsto."
    }
    if ($null -ne $Window.FindName("FolderFormat") -or $null -eq $ResourceFormat -or $ResourceFormat.Items.Count -ne 2 -or [string]$ResourceFormat.Items[0].Tag -ne "v4" -or [string]$ResourceFormat.Items[1].Tag -ne "v5" -or [string]$ResourceFormat.SelectedItem.Tag -ne "v4" -or (Resolve-RequestedResourceFormat $null) -ne "" -or (Resolve-RequestedResourceFormat ([pscustomobject]@{ Tag = "auto" })) -ne "auto" -or $Xaml.OuterXml -notmatch "Cartelle: v4") {
        throw "La UI deve offrire una scelta esplicita v4/v5 per le risorse e mantenere le cartelle v5 bloccate."
    }
    Show-Phase04Workspace "new_import" -SkipRefresh
    $MigrationSeparationValid = ($MigrationWorkspace.Visibility -eq "Visible" -and $ExistingAclWorkspace.Visibility -eq "Collapsed" -and $NewImportWorkspace.Visibility -eq "Visible")
    Show-Phase04Workspace "existing_acl" -SkipRefresh
    $AclSeparationValid = ($MigrationWorkspace.Visibility -eq "Collapsed" -and $ExistingAclWorkspace.Visibility -eq "Visible" -and [string]$AclWorkspaceButton.Content -eq "Torna alla migrazione")
    Show-Phase04Workspace "new_import" -SkipRefresh
    if (-not $MigrationSeparationValid -or -not $AclSeparationValid -or $ImportWorkspaceTabs.Items.Count -ne 4 -or $null -eq $PreflightGrid -or $null -eq $VerificationGrid -or $null -eq $BatchActivityGrid -or $null -eq $SourceFeedbackButton -or $null -eq $ExportPreflightReceiptButton -or $null -eq $ExportMigrationReceiptButton -or $ExportPreflightReceiptButton.IsEnabled -or $ExportMigrationReceiptButton.IsEnabled -or $RecoveryConfirmation.IsEnabled -or $VerifyRecoveryButton.IsEnabled -or $ExecuteRecoveryButton.IsEnabled -or (Get-RecoveryStatusLabel "recovery_required") -ne "Recuperabile") {
        throw "I controlli UI del recupero guidato non sono nello stato fail-closed previsto."
    }
    $script:ImportCandidates = @(
        [pscustomobject]@{ candidate_id = "aaaaaaaaaaaaaaaa"; title = "Risorsa dashboard" },
        [pscustomobject]@{ candidate_id = "bbbbbbbbbbbbbbbb"; title = "Duplicato dashboard" }
    )
    Initialize-ImportDashboard 1 1
    Update-ImportDashboardProgress ([pscustomobject]@{ type = "progress"; event_type = "duplicate_skipped"; payload = [pscustomobject]@{ candidate_id = "bbbbbbbbbbbbbbbb"; duplicate_kind = "batch" } })
    Update-ImportDashboardProgress ([pscustomobject]@{ type = "progress"; event_type = "resource_created"; payload = [pscustomobject]@{ candidate_id = "aaaaaaaaaaaaaaaa"; resource_id = "11111111-1111-4111-8111-111111111111" } })
    Update-ImportDashboardProgress ([pscustomobject]@{ type = "progress"; event_type = "resource_verified"; payload = [pscustomobject]@{ candidate_id = "aaaaaaaaaaaaaaaa"; resource_id = "11111111-1111-4111-8111-111111111111" } })
    Update-ImportDashboardProgress ([pscustomobject]@{ type = "progress"; event_type = "batch_completed"; payload = [pscustomobject]@{ verified_resource_count = 1 } })
    if ($BatchProgressBar.Value -ne 100 -or [string]$BatchMetricCompleted.Text -ne "2 / 2" -or [string]$BatchMetricVerified.Text -ne "1" -or $BatchActivityGrid.Items.Count -lt 5) {
        throw "La dashboard operativa non aggiorna avanzamento, duplicati e verifica finale."
    }
    Reset-ImportOperationalViews
    if ($null -ne $Window.FindName("ServerFingerprint") -or [string]$DetectedFingerprint.Text -ne "Fingerprint: non ancora rilevata" -or $DetectedFingerprint.IsDescendantOf($ConfigurationPage)) {
        throw "La fase 04 deve rilevare la fingerprint senza richiedere un inserimento manuale o bloccare la preparazione locale."
    }
    $script:ImportCandidates = @(
        [pscustomobject]@{ client = "Cliente Alfa" },
        [pscustomobject]@{ client = "Cliente Beta" }
    )
    $script:AvailableDestinationFolders = @(
        [pscustomobject]@{ id = "folder-alpha-id"; path = "Clienti / Cliente Alfa" }
    )
    $script:DestinationFolderCatalogLoaded = $true
    $script:ClientDestinationMap = @{
        "Cliente Alfa" = "folder-alpha-id"
        "Cliente Beta" = "__root__"
    }
    $ClientMappingProbe = @(Get-ClientDestinationMappingPayload)
    if ($ClientMappingProbe.Count -ne 2 -or @($ClientMappingProbe | Where-Object { $null -eq $_.folder_id }).Count -ne 1) {
        throw "La mappatura UI delle destinazioni per cliente non e' valida."
    }
    $DestinationMode.SelectedIndex = 1
    Update-DestinationControlState
    if (-not $ConfigureClientMappingsButton.IsEnabled -or $ConfigureClientMappingsButton.Visibility -ne "Visible") {
        throw "I controlli UI della mappatura per cliente non sono nello stato previsto."
    }
    $ClientMappingDialogProbe = Show-ClientDestinationMappingDialog -BuildOnly
    if ($null -eq $ClientMappingDialogProbe -or $ClientMappingDialogProbe.Editors.Count -ne 2) {
        throw "La finestra UI della mappatura per cliente non puo essere costruita."
    }
    $ClientMappingDialogProbe.Window.Close()
    $script:PermissionCatalog = @(
        [pscustomobject]@{
            aro = "User"
            aro_foreign_key = "permission-user-probe"
            subject_type = "Utente"
            display_name = "Utente test"
            detail = "utente@example.invalid"
            available = $true
            unavailable_reason = $null
        }
    )
    $PermissionEditorProbe = Show-PermissionEditor -BuildOnly
    if ($null -eq $PermissionEditorProbe -or $null -eq $PermissionEditorProbe.SelectedGrid -or $PermissionEditorProbe.DirectoryList.Items.Count -ne 1) {
        throw "L'editor UI dei permessi non puo essere costruito nello stato previsto."
    }
    $PermissionEditorProbe.Window.Close()
    Set-AclCatalogResult ([pscustomobject]@{
        command = "acl-catalog"
        read_only = $true
        write_requests = 0
        folder_count = 1
        resource_count = 0
        shared_count = 1
        verified_count = 1
        warning_count = 0
        objects = @([pscustomobject]@{
            object_type = "folder"
            object_type_label = "Cartella"
            object_id = "acl-folder-probe"
            name = "Cliente ACL"
            path = "Clienti / Cliente ACL"
            current_access_type = 15
            current_access_label = "Proprietario"
            sharing_label = "Condiviso"
            inspection_status = "verified"
            acl_complete = $true
            subjects_verified = $true
            warnings = @()
            permissions = @(
                [pscustomobject]@{ subject_kind = "User"; subject_type = "Utente diretto"; subject_id = "owner-probe"; display_name = "Proprietario test"; detail = "owner@example.invalid"; permission_type = 15; permission_label = "Proprietario"; current_user = $true; verified = $true; verification_status = "Chiave verificata"; recipient_count = 1 },
                [pscustomobject]@{ subject_kind = "Group"; subject_type = "Gruppo"; subject_id = "group-probe"; display_name = "Team test"; detail = "2 destinatari effettivi verificati"; permission_type = 1; permission_label = "Lettura"; current_user = $false; verified = $true; verification_status = "Composizione e chiavi verificate"; recipient_count = 2 }
            )
        })
    })
    if ($AclObjectsGrid.Items.Count -ne 1 -or $AclPermissionsGrid.Items.Count -ne 2 -or [string]$AclObjectSummary.Text -notmatch "Cliente ACL") {
        throw "Il visualizzatore UI delle ACL esistenti non espone oggetti e permessi nello stato previsto."
    }
    $script:ImportSessionProcess = [System.Diagnostics.Process]::GetCurrentProcess()
    $script:ImportSessionId = "uncertain-acl-guard-probe"
    $script:AclCatalogSessionId = $script:ImportSessionId
    $script:AclRecoveryRequired = $false
    Update-AclPlanActionState
    if (-not $AclPlanButton.IsEnabled) {
        throw "Il probe della guardia ACL non raggiunge lo stato pronto iniziale."
    }
    $script:AclRecoveryRequired = $true
    $script:AclRecoveryBlockingCount = 1
    $script:AclPlan = [pscustomobject]@{ apply_available = $true; confirmation_required = "CONFERMO ACL PROBE" }
    $AclConfirmation.Text = "CONFERMO ACL PROBE"
    Update-AclPlanActionState
    Update-AclApplyActionState
    if ($AclPlanButton.IsEnabled -or $ApplyAclButton.IsEnabled -or $AclConfirmation.IsEnabled -or [string]$AclPlanButton.ToolTip -notmatch "Recupero obbligatorio" -or [string]$ApplyAclButton.ToolTip -notmatch "Recupero obbligatorio") {
        throw "Un esito ACL incerto non blocca dry-run e applicazione a favore del recupero."
    }
    Reset-AclPlan
    $script:AclRecoveryRequired = $false
    $script:AclRecoveryBlockingCount = 0
    $script:ImportSessionProcess = $null
    $script:ImportSessionId = ""
    $script:AclCatalogSessionId = ""
    Update-AclPlanActionState
    $AclPlanEditorProbe = Show-PermissionEditor -BuildOnly -AclPlanMode -InitialPermissions @([pscustomobject]@{ aro = "User"; aro_foreign_key = "permission-user-probe"; type = 7 }) -TargetPath "Clienti / Cliente ACL"
    if ($null -eq $AclPlanEditorProbe -or -not $AclPlanEditorProbe.PlanMode -or $AclPlanEditorProbe.SelectedGrid.Items.Count -ne 1 -or $AclPlanEditorProbe.DirectoryList.Items.Count -ne 1) {
        throw "L'editor UI del dry-run ACL non puo essere costruito nello stato previsto."
    }
    $AclPlanEditorProbe.Window.Close()
    Set-AclPlanResult ([pscustomobject]@{
        command = "acl-plan"
        read_only = $true
        write_requests = 0
        remote_writes_planned = 0
        complete = $true
        generated_from_fresh_remote_state = $true
        plan_id = "acl-plan-probe"
        object_state_digest = ("a" * 64)
        desired_acl_digest = ("b" * 64)
        directory_state_digest = ("d" * 64)
        plan_digest = ("c" * 64)
        change_count = 1
        sensitive_action_count = 1
        apply_available = $true
        additive_apply_available = $false
        restrictive_apply_available = $true
        restrictive_change_count = 1
        restrictive_changes_blocked = 0
        apply_mode = "restrictive"
        destructive_actions_planned = $true
        confirmation_required = "CONFERMO RIDUZIONE ACL 1 0 CCCCCCCC"
        counts = [pscustomobject]@{ add = 0; upgrade = 0; downgrade = 1; revoke = 0; unchanged = 1 }
        effective_user_counts = [pscustomobject]@{ before = 3; after = 3; gain = 0; loss = 0; upgrade = 0; downgrade = 2 }
        effective_user_changes = @([pscustomobject]@{ action = "downgrade"; display_name = "Utente test" })
        last_owner_protection = [pscustomobject]@{ owner_count_before = 1; owner_count_after = 1; current_user_owner_retained = $true; protected = $true }
        object = [pscustomobject]@{ object_type = "folder"; object_id = "acl-folder-probe"; path = "Clienti / Cliente ACL" }
        operations = @([pscustomobject]@{
            sequence = 1
            action = "downgrade"
            action_label = "Riduzione livello"
            subject_type = "Gruppo"
            subject_id = "group-probe"
            display_name = "Team test"
            detail = "2 destinatari effettivi verificati"
            before_permission_label = "Aggiornamento"
            after_permission_label = "Lettura"
            direction_label = "Riduce accesso"
            risk_label = "Sensibile"
            sensitive = $true
        })
    })
    if ($AclPlanGrid.Items.Count -ne 1 -or $AclDetailTabs.SelectedIndex -ne 1 -or [string]$AclPlanSummary.Text -notmatch "riduzioni 1" -or $null -eq $script:AclPlan) {
        throw "La vista UI del piano ACL read-only non espone il confronto nello stato previsto."
    }
    if ($ApplyAclButton.IsEnabled -or $AclConfirmation.IsEnabled -or $null -eq $RecoverAclButton) {
        throw "I controlli UI ACL non rispettano il requisito di una sessione autenticata attiva."
    }
    $AclJournalManagerProbe = Show-AclJournalManager -BuildOnly
    if ($null -eq $AclJournalManagerProbe -or $null -eq $AclJournalManagerProbe.Grid -or $AclJournalManagerProbe.Grid.Rows.Count -ne 1 -or [string]$AclJournalManagerProbe.Grid.Rows[0].Cells[3].Value -ne "acl-journal-ui-probe" -or $AclJournalManagerProbe.StatusFilter.Items.Count -ne 5 -or $AclJournalManagerProbe.TypeFilter.Items.Count -ne 3 -or $AclJournalManagerProbe.DateFilter.Items.Count -ne 4 -or $null -eq $AclJournalManagerProbe.ArchiveButton) {
        throw "La gestione UI dei journal ACL non espone elenco, filtri, dettaglio e archiviazione."
    }
    $AclJournalManagerProbe.Window.Close()
    Reset-AclPlan
    if ([bool]$ReviewPasswordToggle.IsChecked -or [string]$ReviewPasswordState.Text -ne "PASSWORD MASCHERATE") {
        throw "Il controllo di visualizzazione password non e' mascherato per impostazione predefinita."
    }
    $ExcelPasswordDialogProbe = Show-ExcelPasswordDialog "Cliente Alfa/credenziali.xlsx" -BuildOnly
    if (
        $null -eq $ExcelPasswordDialogProbe -or
        $ExcelPasswordDialogProbe.PasswordBox.MaxLength -ne 1024 -or
        $ExcelPasswordDialogProbe.PasswordText.Visibility -ne "Collapsed" -or
        [string]::IsNullOrWhiteSpace([System.Windows.Automation.AutomationProperties]::GetName($ExcelPasswordDialogProbe.PasswordBox)) -or
        [string]::IsNullOrWhiteSpace([System.Windows.Automation.AutomationProperties]::GetName($ExcelPasswordDialogProbe.PasswordText))
    ) {
        throw "La richiesta protetta della password Excel non puo essere costruita nello stato previsto."
    }
    $ExcelPasswordDialogProbe.Window.Close()
    $SourceProfileDialogProbe = Show-SourceMappingProfileDialog -BuildOnly
    if ($null -eq $SourceProfileDialogProbe -or $SourceProfileDialogProbe.Editors.Count -ne 5 -or $null -eq $SourceProfileDialogProbe.ApplyButton -or $null -eq $SourceProfileDialogProbe.ResetButton -or @($SourceProfileDialogProbe.Editors.Values | Where-Object { [string]::IsNullOrWhiteSpace([System.Windows.Automation.AutomationProperties]::GetName($_)) }).Count -gt 0) {
        throw "La finestra dei profili sorgente non espone mapping, validazione e ripristino automatico."
    }
    $SourceProfileDialogProbe.Window.Close()
    $ReviewEditorRowProbe = [pscustomobject]@{
        CandidateId = "review-editor-probe"
        Client = "Cliente Alfa"
        Title = "Portale"
        Username = "utente"
        Uri = "10.0.0.1"
        OriginalClient = "Cliente Alfa"
        OriginalSourceAtRoot = $false
        OriginalTitle = "Portale"
        OriginalUsername = "utente"
        OriginalUri = "10.0.0.1"
        SecretPresent = $true
        SecretLength = 16
        SecretValue = "self-test-secret"
        SecretCachedFromSource = $true
        PasswordOverridden = $false
        IsEdited = $false
        Status = "ready"
        StatusLabel = "Pronto"
        SecretDisplay = "******** (16)"
        SourcePasswordRequired = $false
        SourceRelativePath = "Cliente Alfa/portale.txt"
        SourceHash = ("a" * 64)
        SourceMappingDigest = ""
        SourceMappingProfile = $null
    }
    $ReviewEditorProbe = Show-ReviewCandidateEditor $ReviewEditorRowProbe -BuildOnly
    if ($null -eq $ReviewEditorProbe -or $ReviewEditorProbe.Editors.Count -ne 5 -or @($ReviewEditorProbe.Editors.Values | Where-Object { [string]::IsNullOrWhiteSpace([System.Windows.Automation.AutomationProperties]::GetName($_)) }).Count -gt 0 -or [string]::IsNullOrWhiteSpace([System.Windows.Automation.AutomationProperties]::GetName($ReviewEditorProbe.PasswordText))) {
        throw "L'editor dei candidati non espone i cinque campi previsti."
    }
    $ReviewEditorProbe.Window.Close()
    $ConflictDiagnosticProbe = Get-ImportReadinessDiagnostic ([pscustomobject]@{
        can_import = $false
        blocked_count = 2
        unavailable_reason = "2 credenziali esistono in una cartella diversa dalla destinazione prevista."
        preflight_checks = @([pscustomobject]@{ id = "conflicts"; status = "blocked" })
    })
    $CapabilityDiagnosticProbe = Get-ImportReadinessDiagnostic ([pscustomobject]@{
        can_import = $false
        blocked_count = 0
        unavailable_reason = "Il server non consente alcun tipo password v4 o v5 compatibile."
        preflight_checks = @([pscustomobject]@{ id = "resource_format"; status = "blocked" })
    })
    $V5PolicyDiagnosticProbe = Get-ImportReadinessDiagnostic ([pscustomobject]@{
        can_import = $false
        blocked_count = 0
        unavailable_reason = "Il profilo preview consente risorse v5 personali ma blocca le modifiche ACL necessarie per creare o condividere una risorsa v5 condivisa."
        preflight_checks = @([pscustomobject]@{ id = "permission_directory"; status = "blocked" })
    })
    $ImportablePlanProbe = [pscustomobject]@{
        can_import = $true
        preflight_status = "passed"
        create_count = 1
        blocked_count = 0
        unavailable_reason = $null
        plan_digest = ("a" * 64)
        candidates = @([pscustomobject]@{ action = "create" })
        preflight_checks = @([pscustomobject]@{ id = "conflicts"; status = "passed" })
    }
    $ImportableDiagnosticProbe = Get-ImportReadinessDiagnostic $ImportablePlanProbe
    $UnsafeDiagnosticMarker = "REMOTE-VALUE-MUST-NOT-APPEAR"
    $MalformedDiagnosticProbe = Get-ImportReadinessDiagnostic ([pscustomobject]@{
        can_import = "true"
        blocked_count = "2"
        unavailable_reason = "$UnsafeDiagnosticMarker`r`npassword=synthetic"
        preflight_checks = @([pscustomobject]@{ id = $UnsafeDiagnosticMarker; status = "blocked" })
    })
    $IncoherentDiagnosticProbe = Get-ImportReadinessDiagnostic ([pscustomobject]@{
        can_import = $true
        preflight_status = "blocked"
        create_count = 1
        blocked_count = 1
        unavailable_reason = $null
        plan_digest = ("b" * 64)
        candidates = @([pscustomobject]@{ action = "blocked" })
        preflight_checks = @([pscustomobject]@{ id = "conflicts"; status = "blocked" })
    })
    if (
        [bool]$ConflictDiagnosticProbe.CanImport -or
        [string]$ConflictDiagnosticProbe.ActivityCode -ne "destination_conflict" -or
        [string]$ConflictDiagnosticProbe.Cause -notmatch "destinazione diversa" -or
        [string]$ConflictDiagnosticProbe.Hint -match "capabilit" -or
        [bool]$CapabilityDiagnosticProbe.CanImport -or
        [string]$CapabilityDiagnosticProbe.ActivityCode -ne "server_capability_missing" -or
        [string]$CapabilityDiagnosticProbe.Cause -notmatch "capability Passbolt" -or
        [bool]$V5PolicyDiagnosticProbe.CanImport -or
        [string]$V5PolicyDiagnosticProbe.ActivityCode -ne "v5_acl_mutation_disabled" -or
        [string]$V5PolicyDiagnosticProbe.Cause -notmatch "import v5 condivisi" -or
        -not [bool]$ImportableDiagnosticProbe.CanImport -or
        -not (Test-ImportPlanCanImport $ImportablePlanProbe) -or
        (Test-ImportPlanCanImport ([pscustomobject]@{ can_import = "true" })) -or
        [bool]$MalformedDiagnosticProbe.CanImport -or
        [string]$MalformedDiagnosticProbe.ActivityCode -ne "preflight_result_invalid" -or
        "$($MalformedDiagnosticProbe.Cause) $($MalformedDiagnosticProbe.Hint) $($MalformedDiagnosticProbe.ActivityCode)" -match $UnsafeDiagnosticMarker -or
        [bool]$IncoherentDiagnosticProbe.CanImport -or
        [string]$IncoherentDiagnosticProbe.ActivityCode -ne "preflight_result_invalid"
    ) {
        throw "La diagnostica sintetica del preflight non distingue in modo fail-closed conflitti, capability e piani importabili."
    }
    $ImportReadinessDiagnosticCaseCount = 6
    [pscustomobject]@{
        app = "Passbolt Migration Assistant"
        version = "0.29.0-beta.1"
        ui = "WPF"
        phases = 4
        controls = 140
        import_readiness_diagnostic_cases = $ImportReadinessDiagnosticCaseCount
        inventory_collection = "OK"
        review_backend = "OK"
        import_backend = "OK"
        openpgp_backend = "OK"
        process_argument_quoting = "OK"
        persistent_process_transport = "OK"
        client_mapping_ui = "OK"
        permission_editor_ui = "OK"
        existing_acl_viewer_ui = "OK"
        existing_acl_dry_run_ui = "OK"
        existing_acl_additive_apply_ui = "OK"
        existing_acl_restrictive_apply_ui = "OK"
        existing_acl_recovery_ui = "OK"
        acl_journal_management_ui = "OK"
        review_password_toggle = "OK"
        review_candidate_editor = "OK"
        source_mapping_profile_ui = "OK"
        protected_local_project_ui = "OK"
        dpapi_current_user_probe = $(if ($LocalProjectDpapiProbeAvailable) { "OK" } else { "profile_unavailable" })
        protected_excel_password_prompt = "OK"
        sanitized_source_feedback = "OK"
        sanitized_migration_receipts = "OK"
        persistent_import_session = "OK"
        single_operational_state = "OK"
        operation_reentrancy_guard = "OK"
        centralized_interaction_lock = "OK"
        ordered_dispatcher_progress = "OK"
        asynchronous_worker_lifecycle = "OK"
        manual_event_pump_absent = "OK"
        reconciliation_progress_protocol = "OK"
        batch_dashboard = "OK"
        authenticated_preflight = "OK"
        import_readiness_diagnostics = "OK"
        post_import_verification = "OK"
        authenticated_recovery_protocol = "OK"
        guided_recovery_ui = "OK"
        recoverable_journal_archive = "OK"
        mfa_reused_without_reprompt = "OK"
        automatic_fingerprint_confirmation = "OK"
        safe_login_diagnostics = "OK"
        integration_matrix_backend = "OK"
        unlimited_file_and_candidate_selection = "OK"
        optimized_large_batch_processing = "OK"
        phase04_keyboard_navigation = "OK"
        phase0103_automation_names = "OK"
        minimum_grid_focus_visibility = "OK"
        uncertain_outcome_recovery_guard = "OK"
        modern_apple_ui = "OK"
        offscreen_ui_preview = "OK"
        ci_real_instance_guard = "OK"
        secrets_serialized = $false
        python = $PythonExecutable
        node = $NodeExecutable
        status = "OK"
    } | ConvertTo-Json
    $Window.Close()
    exit 0
}

$Window.ShowDialog() | Out-Null
