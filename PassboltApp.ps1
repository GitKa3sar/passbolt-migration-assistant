param(
    [switch]$SelfTest,
    [string]$RenderPreviewPath = "",
    [ValidateSet("Configuration", "Inventory", "Review", "Import")]
    [string]$RenderPreviewPage = "Configuration",
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

$ProjectRoot = $PSScriptRoot
$ProbeScript = Join-Path $ProjectRoot "passbolt_api_probe.py"
$InventoryScript = Join-Path $ProjectRoot "passbolt_app.py"
$ReviewScript = Join-Path $ProjectRoot "passbolt_review.py"
$ImportScript = Join-Path $ProjectRoot "passbolt_import.py"
$CryptoScript = Join-Path $ProjectRoot "passbolt_crypto.mjs"
$IntegrationMatrixScript = Join-Path $ProjectRoot "passbolt_integration_matrix.py"
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
        Title="Passbolt Migration Assistant - v0.21.0"
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
                            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="InputChrome" Property="BorderBrush" Value="#007AFF" /></Trigger>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="InputChrome" Property="BorderBrush" Value="#AEAEB2" /></Trigger>
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
                            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="PasswordChrome" Property="BorderBrush" Value="#007AFF" /></Trigger>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="PasswordChrome" Property="BorderBrush" Value="#AEAEB2" /></Trigger>
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
                            <Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter Property="BorderBrush" Value="#007AFF" /></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter Property="Background" Value="#F2F2F7" /><Setter Property="Foreground" Value="#8E8E93" /></Trigger>
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
            <Setter Property="FocusVisualStyle" Value="{x:Null}" />
        </Style>
        <Style TargetType="DataGridRow">
            <Setter Property="BorderThickness" Value="0" />
            <Setter Property="FocusVisualStyle" Value="{x:Null}" />
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#F2F7FF" /></Trigger>
                <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#DCEBFF" /><Setter Property="Foreground" Value="#1D1D1F" /></Trigger>
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
                <Border x:Name="StepConfiguration" Background="#FFFFFF" CornerRadius="12" Padding="10,9" Margin="0,3" Cursor="Hand">
                    <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="36" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions><Border Width="27" Height="27" Background="#EAF3FF" CornerRadius="9"><TextBlock x:Name="StepConfigurationNumber" Text="01" Foreground="#007AFF" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center" /></Border><TextBlock x:Name="StepConfigurationText" Grid.Column="1" Text="Configurazione" Foreground="#1D1D1F" FontWeight="SemiBold" VerticalAlignment="Center" /></Grid>
                </Border>
                <Border x:Name="StepInventory" Padding="10,9" Margin="0,3" CornerRadius="12" Cursor="Hand">
                    <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="36" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions><Border Width="27" Height="27" Background="#E5E5EA" CornerRadius="9"><TextBlock x:Name="StepInventoryNumber" Text="02" Foreground="#8E8E93" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center" /></Border><TextBlock x:Name="StepInventoryText" Grid.Column="1" Text="Inventario file" Foreground="#8E8E93" VerticalAlignment="Center" /></Grid>
                </Border>
                <Border x:Name="StepReview" Padding="10,9" Margin="0,3" CornerRadius="12" Cursor="Hand"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="36" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions><Border Width="27" Height="27" Background="#E5E5EA" CornerRadius="9"><TextBlock x:Name="StepReviewNumber" Text="03" Foreground="#8E8E93" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center" /></Border><TextBlock x:Name="StepReviewText" Grid.Column="1" Text="Revisione" Foreground="#8E8E93" VerticalAlignment="Center" /></Grid></Border>
                <Border x:Name="StepImport" Padding="10,9" Margin="0,3" CornerRadius="12" Cursor="Hand"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="36" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions><Border Width="27" Height="27" Background="#E5E5EA" CornerRadius="9"><TextBlock x:Name="StepImportNumber" Text="04" Foreground="#8E8E93" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center" /></Border><TextBlock x:Name="StepImportText" Grid.Column="1" Text="Importazione" Foreground="#8E8E93" VerticalAlignment="Center" /></Grid></Border>
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
                        <RowDefinition Height="Auto" />
                    </Grid.RowDefinitions>
                    <Grid Grid.Row="0" Margin="0,0,0,24">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                        <StackPanel>
                            <TextBlock Text="Configurazione" Style="{StaticResource PageTitle}" />
                            <TextBlock Text="Verifica l&#x2019;istanza Passbolt e indica la cartella principale dei documenti clienti." Style="{StaticResource PageSubtitle}" />
                        </StackPanel>
                        <Border Grid.Column="1" Style="{StaticResource StatusPill}">
                            <TextBlock Text="DRY-RUN ATTIVO" Foreground="#248A3D" FontSize="10" FontWeight="SemiBold" />
                        </Border>
                    </Grid>

                    <Border Grid.Row="1" Style="{StaticResource Card}" Padding="24,20">
                        <StackPanel>
                            <TextBlock Text="1. Connessione Passbolt" Style="{StaticResource SectionTitle}" />
                            <TextBlock Text="Inserisci l'URL. L'app rileva la fingerprint OpenPGP del server e ne richiede la conferma prima di procedere; il controllo pubblico non esegue alcun login." Foreground="{StaticResource MutedBrush}" Margin="0,5,0,16" TextWrapping="Wrap" />
                            <Grid>
                                <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                                <TextBox x:Name="PassboltUrl" ToolTip="URL base HTTPS, ad esempio https://passbolt.example.com" />
                                <Button x:Name="VerifyButton" Grid.Column="1" Content="Verifica connessione" Style="{StaticResource PrimaryButton}" Margin="12,0,0,0" />
                            </Grid>
                            <Grid Margin="0,10,0,0">
                                <Grid.ColumnDefinitions><ColumnDefinition Width="150" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions>
                                <TextBlock Text="Fingerprint rilevata" Foreground="{StaticResource MutedBrush}" VerticalAlignment="Center" />
                                <Border Grid.Column="1" Background="#F5F5F7" BorderBrush="#E5E5EA" BorderThickness="1" CornerRadius="10" Padding="12,9">
                                    <TextBlock x:Name="DetectedFingerprint" Text="Non ancora rilevata" Foreground="#3A3A3C" FontFamily="Cascadia Mono, Consolas" FontSize="11" TextWrapping="Wrap" />
                                </Border>
                            </Grid>
                            <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                                <Ellipse x:Name="ConnectionDot" Width="9" Height="9" Fill="#98A5B1" Margin="0,0,7,0" />
                                <TextBlock x:Name="ConnectionStatus" Text="Non verificata" Foreground="{StaticResource MutedBrush}" />
                            </StackPanel>
                        </StackPanel>
                    </Border>

                    <Border Grid.Row="2" Style="{StaticResource Card}" Padding="24,20">
                        <StackPanel>
                            <TextBlock Text="2. Cartella documenti clienti" Style="{StaticResource SectionTitle}" />
                            <TextBlock Text="Ogni cartella di primo livello viene considerata un cliente. I file nella radice restano separati." Foreground="{StaticResource MutedBrush}" Margin="0,5,0,16" />
                            <Grid>
                                <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                                <TextBox x:Name="ClientFolder" />
                                <Button x:Name="BrowseButton" Grid.Column="1" Content="Scegli cartella" Style="{StaticResource SecondaryButton}" Margin="12,0,0,0" />
                            </Grid>
                            <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                                <Ellipse x:Name="FolderDot" Width="9" Height="9" Fill="#98A5B1" Margin="0,0,7,0" />
                                <TextBlock x:Name="FolderStatus" Text="Nessuna cartella selezionata" Foreground="{StaticResource MutedBrush}" />
                            </StackPanel>
                        </StackPanel>
                    </Border>

                    <Grid Grid.Row="3" Margin="0,4,0,0">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                        <StackPanel VerticalAlignment="Center">
                            <CheckBox Content="Modalit&#xE0; simulazione obbligatoria" IsChecked="True" IsEnabled="False" />
                            <TextBlock Text="La fase successiva raccoglie esclusivamente metadati dei file." Foreground="{StaticResource MutedBrush}" FontSize="11" Margin="27,4,0,0" />
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
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /><ColumnDefinition Width="Auto" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                    <StackPanel>
                        <TextBlock Text="Inventario file" Style="{StaticResource PageTitle}" />
                        <TextBlock x:Name="InventoryRoot" Text="Inventario non ancora eseguito" Style="{StaticResource PageSubtitle}" FontSize="12" TextTrimming="CharacterEllipsis" />
                    </StackPanel>
                    <Button x:Name="RefreshButton" Grid.Column="1" Content="Aggiorna inventario" Style="{StaticResource SecondaryButton}" VerticalAlignment="Center" />
                    <Button x:Name="ExportButton" Grid.Column="2" Content="Esporta CSV" Style="{StaticResource SecondaryButton}" Margin="8,0,0,0" VerticalAlignment="Center" IsEnabled="False" />
                    <Button x:Name="ReviewSelectionButton" Grid.Column="3" Content="Rivedi selezionati (0)" Style="{StaticResource PrimaryButton}" Margin="8,0,0,0" VerticalAlignment="Center" IsEnabled="False" />
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
                        <ComboBox x:Name="ClientFilter" Grid.Column="0" />
                        <ComboBox x:Name="FormatFilter" Grid.Column="1" Margin="8,0,0,0" />
                        <TextBox x:Name="SearchBox" Grid.Column="2" Margin="8,0,0,0" ToolTip="Cerca nel cliente o nel percorso relativo" />
                        <TextBlock x:Name="FilterStatus" Grid.Column="3" Text="0 file" Foreground="#66737F" VerticalAlignment="Center" Margin="14,0,0,0" />
                    </Grid>
                </Border>

                <Border Grid.Row="3" Style="{StaticResource Card}" Margin="0" Padding="0">
                    <Grid>
                        <Grid.RowDefinitions><RowDefinition Height="*" /><RowDefinition Height="Auto" /></Grid.RowDefinitions>
                        <DataGrid x:Name="FilesGrid" Grid.Row="0" AutoGenerateColumns="False" AlternationCount="2" SelectionMode="Extended" SelectionUnit="FullRow" ToolTip="Seleziona pi&#xF9; file con Ctrl o Maiusc" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling">
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
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions>
                    <Button x:Name="BackButton" Content="&#x2190;  Torna alla configurazione" Style="{StaticResource SecondaryButton}" />
                    <TextBox x:Name="ActivityLog" Grid.Column="1" Margin="12,0,0,0" Height="42" IsReadOnly="True" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" FontFamily="Cascadia Mono, Consolas" FontSize="10" Background="#F2F2F7" BorderBrush="#E5E5EA" />
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
                        <ComboBox x:Name="ReviewStatusFilter" Grid.Column="0" />
                        <TextBox x:Name="ReviewSearchBox" Grid.Column="1" Margin="8,0,0,0" ToolTip="Cerca in cliente, titolo, username, URL o origine" />
                        <ToggleButton x:Name="ReviewPasswordToggle" Grid.Column="2" Content="Mostra password" Margin="8,0,0,0" Padding="12,7" VerticalAlignment="Stretch" ToolTip="Mostra temporaneamente le password dei candidati caricandole soltanto in memoria" />
                        <Button x:Name="EditReviewCandidateButton" Grid.Column="3" Content="Modifica..." Style="{StaticResource SecondaryButton}" Margin="8,0,0,0" Padding="14,7" IsEnabled="False" ToolTip="Modifica il candidato selezionato prima dell'importazione" />
                        <TextBlock x:Name="ReviewFilterStatus" Grid.Column="4" Text="0 candidati" Foreground="#66737F" VerticalAlignment="Center" Margin="14,0,0,0" />
                    </Grid>
                </Border>

                <Border Grid.Row="3" Style="{StaticResource Card}" Margin="0" Padding="0">
                    <Grid>
                        <Grid.RowDefinitions><RowDefinition Height="*" /><RowDefinition Height="Auto" /></Grid.RowDefinitions>
                        <DataGrid x:Name="ReviewCandidatesGrid" Grid.Row="0" AutoGenerateColumns="False" AlternationCount="2" SelectionMode="Extended" SelectionUnit="FullRow" ToolTip="Seleziona i candidati pronti con Ctrl o Maiusc" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling">
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
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto" /><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                    <Button x:Name="ReviewBackButton" Content="&#x2190;  Torna all&#x2019;inventario" Style="{StaticResource SecondaryButton}" />
                    <TextBlock Grid.Column="1" Text="Le password sono mascherate per impostazione predefinita; quando richieste restano solo in memoria e non vengono salvate o registrate." Foreground="#66737F" FontSize="11" VerticalAlignment="Center" Margin="14,0" TextWrapping="Wrap" />
                    <Button x:Name="PrepareImportButton" Grid.Column="2" Content="Prepara importazione (0)" Style="{StaticResource PrimaryButton}" IsEnabled="False" />
                </Grid>
            </Grid>

            <Grid x:Name="ImportPage" Visibility="Collapsed" Margin="34,28,34,26">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto" />
                    <RowDefinition Height="Auto" />
                    <RowDefinition Height="Auto" />
                    <RowDefinition Height="*" />
                    <RowDefinition Height="Auto" />
                </Grid.RowDefinitions>

                <Grid Grid.Row="0" Margin="0,0,0,14">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                    <StackPanel>
                        <TextBlock Text="Importazione controllata" Style="{StaticResource PageTitle}" />
                        <TextBlock x:Name="ImportSummary" Text="Prepara i candidati dalla revisione" Style="{StaticResource PageSubtitle}" FontSize="12" />
                    </StackPanel>
                    <Border Grid.Column="1" Style="{StaticResource StatusPill}">
                        <TextBlock Text="GPGAuth + OPENPGP LOCALE" Foreground="#248A3D" FontSize="10" FontWeight="SemiBold" />
                    </Border>
                </Grid>

                <Border Grid.Row="1" Style="{StaticResource InfoBanner}" Margin="0,0,0,14">
                    <TextBlock Text="Avvia la sessione una sola volta con chiave privata, passphrase e MFA. L'identita OpenPGP e la sessione Passbolt restano esclusivamente in memoria e vengono riutilizzate per dry-run e importazioni successive; si chiudono su richiesta, alla chiusura dell'app o dopo 30 minuti di inattivita." Foreground="#355E85" FontSize="11" TextWrapping="Wrap" LineHeight="17" />
                </Border>

                <Border Grid.Row="2" Style="{StaticResource Card}" Padding="18,16">
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="28" /><ColumnDefinition Width="1.08*" /></Grid.ColumnDefinitions>
                        <Border Grid.Column="1" Width="1" Background="#E5E5EA" HorizontalAlignment="Center" />

                        <Grid Grid.Column="0">
                            <Grid.RowDefinitions><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /></Grid.RowDefinitions>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="105" /><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                            <TextBlock Grid.Row="0" Grid.ColumnSpan="3" Text="Sessione sicura" Style="{StaticResource SectionTitle}" Margin="0,0,0,10" />
                            <TextBlock Grid.Row="1" Text="Chiave privata" Foreground="{StaticResource MutedBrush}" VerticalAlignment="Center" />
                            <TextBox x:Name="PrivateKeyPath" Grid.Row="1" Grid.Column="1" ToolTip="File ASCII-armored della chiave privata Passbolt" />
                            <Button x:Name="BrowseKeyButton" Grid.Row="1" Grid.Column="2" Content="Scegli file" Style="{StaticResource SecondaryButton}" Margin="8,0,0,0" />
                            <TextBlock Grid.Row="2" Text="Passphrase" Foreground="{StaticResource MutedBrush}" VerticalAlignment="Center" Margin="0,8,0,0" />
                            <PasswordBox x:Name="KeyPassphrase" Grid.Row="2" Grid.Column="1" Grid.ColumnSpan="2" Margin="0,8,0,0" ToolTip="Usata solo per aprire la sessione; non viene salvata e il campo viene subito cancellato" />
                            <TextBlock Grid.Row="3" Text="MFA (TOTP)" Foreground="{StaticResource MutedBrush}" VerticalAlignment="Center" Margin="0,8,0,0" />
                            <PasswordBox x:Name="MfaTotpCode" Grid.Row="3" Grid.Column="1" Margin="0,8,0,0" MaxLength="6" ToolTip="Usato solo per aprire la sessione; non viene salvato e il campo viene subito cancellato" />
                            <Button x:Name="ImportSessionButton" Grid.Row="3" Grid.Column="2" Content="Avvia sessione" Style="{StaticResource SecondaryButton}" Margin="8,8,0,0" />
                        </Grid>

                        <Grid Grid.Column="2">
                            <Grid.RowDefinitions><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /></Grid.RowDefinitions>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="135" /><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                            <TextBlock Grid.Row="0" Grid.ColumnSpan="3" Text="Destinazione e formato" Style="{StaticResource SectionTitle}" Margin="0,0,0,10" />
                            <TextBlock Grid.Row="1" Text="Destinazione" Foreground="{StaticResource MutedBrush}" VerticalAlignment="Center" />
                            <ComboBox x:Name="DestinationMode" Grid.Row="1" Grid.Column="1" Grid.ColumnSpan="2" SelectedIndex="0" ToolTip="Crea o riutilizza una cartella per ogni cliente; in un contenitore condiviso eredita la maschera dei permessi verificata">
                                <ComboBoxItem Content="Cartelle per cliente nel contenitore scelto" Tag="client_folders" />
                                <ComboBoxItem Content="Mappatura distinta per ogni cliente" Tag="client_mapping" />
                                <ComboBoxItem Content="Direttamente nella cartella scelta" Tag="direct_folder" />
                                <ComboBoxItem Content="Radice personale Passbolt" Tag="root" />
                            </ComboBox>
                            <TextBlock Grid.Row="2" Text="Cartella Passbolt" Foreground="{StaticResource MutedBrush}" VerticalAlignment="Center" Margin="0,8,0,0" />
                            <ComboBox x:Name="DestinationFolder" Grid.Row="2" Grid.Column="1" Grid.ColumnSpan="2" Margin="0,8,0,0" SelectedIndex="0" MaxDropDownHeight="300" ToolTip="Il primo dry-run carica le cartelle Passbolt accessibili">
                                <ComboBoxItem Content="Radice personale Passbolt" Tag="" />
                            </ComboBox>
                            <Button x:Name="ConfigureClientMappingsButton" Grid.Row="2" Grid.Column="1" Grid.ColumnSpan="2" HorizontalAlignment="Left" Content="Mappa clienti" Style="{StaticResource SecondaryButton}" Margin="0,8,0,0" IsEnabled="False" Visibility="Collapsed" />
                            <TextBlock Grid.Row="3" Text="Permessi" Foreground="{StaticResource MutedBrush}" VerticalAlignment="Center" Margin="0,8,0,0" />
                            <TextBlock x:Name="PermissionModeStatus" Grid.Row="3" Grid.Column="1" Text="Ereditati dalla destinazione" Foreground="{StaticResource MutedBrush}" VerticalAlignment="Center" Margin="0,8,8,0" TextWrapping="Wrap" ToolTip="I permessi personalizzati vengono applicati soltanto alle nuove cartelle e risorse; il proprietario autenticato resta sempre Owner" />
                            <Button x:Name="ConfigurePermissionsButton" Grid.Row="3" Grid.Column="2" Content="Modifica permessi..." Style="{StaticResource SecondaryButton}" Margin="0,8,0,0" IsEnabled="False" />
                            <TextBlock Grid.Row="4" Text="Formato cartelle" Foreground="{StaticResource MutedBrush}" VerticalAlignment="Center" Margin="0,8,0,0" />
                            <ComboBox x:Name="FolderFormat" Grid.Row="4" Grid.Column="1" Grid.ColumnSpan="2" Margin="0,8,0,0" SelectedIndex="0" ToolTip="Automatico usa il formato predefinito; le nuove cartelle in un contenitore condiviso ne ereditano i permessi">
                                <ComboBoxItem Content="Automatico (predefinito server)" Tag="auto" />
                                <ComboBoxItem Content="v4 - nome in chiaro" Tag="v4" />
                                <ComboBoxItem Content="v5 - nome cifrato" Tag="v5" />
                            </ComboBox>
                            <TextBlock Grid.Row="5" Text="Formato risorse" Foreground="{StaticResource MutedBrush}" VerticalAlignment="Center" Margin="0,8,0,0" />
                            <ComboBox x:Name="ResourceFormat" Grid.Row="5" Grid.Column="1" Margin="0,8,0,0" SelectedIndex="0" ToolTip="Automatico usa il formato predefinito dall'istanza Passbolt">
                                <ComboBoxItem Content="Automatico (predefinito server)" Tag="auto" />
                                <ComboBoxItem Content="v4 - metadati in chiaro" Tag="v4" />
                                <ComboBoxItem Content="v5 - metadati cifrati" Tag="v5" />
                            </ComboBox>
                            <Button x:Name="DryRunButton" Grid.Row="5" Grid.Column="2" Content="Verifica e dry-run" Style="{StaticResource PrimaryButton}" Margin="8,8,0,0" IsEnabled="False" />
                        </Grid>
                    </Grid>
                </Border>

                <TabControl x:Name="ImportModeTabs" Grid.Row="3" Grid.RowSpan="2" Margin="0,12,0,0">
                    <TabItem Header="Nuova importazione">
                        <Grid Margin="8,10,8,8">
                            <Grid.RowDefinitions><RowDefinition Height="Auto" /><RowDefinition Height="*" /><RowDefinition Height="Auto" /></Grid.RowDefinitions>
                            <Grid Grid.Row="0" Margin="0,0,0,10">
                                <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="*" /><ColumnDefinition Width="*" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions>
                                <Border Grid.Column="0" Style="{StaticResource Card}" Margin="0,0,5,0"><StackPanel><TextBlock Text="Selezionati" Foreground="#66737F" /><TextBlock x:Name="ImportMetricSelected" Text="&#x2014;" FontSize="22" FontWeight="Bold" Foreground="#1F2933" /></StackPanel></Border>
                                <Border Grid.Column="1" Style="{StaticResource Card}" Margin="5,0"><StackPanel><TextBlock Text="Da creare" Foreground="#66737F" /><TextBlock x:Name="ImportMetricCreate" Text="&#x2014;" FontSize="22" FontWeight="Bold" Foreground="#16875D" /></StackPanel></Border>
                                <Border Grid.Column="2" Style="{StaticResource Card}" Margin="5,0"><StackPanel><TextBlock Text="Duplicati esatti" Foreground="#66737F" /><TextBlock x:Name="ImportMetricDuplicates" Text="&#x2014;" FontSize="22" FontWeight="Bold" Foreground="#B7791F" /></StackPanel></Border>
                                <Border Grid.Column="3" Style="{StaticResource Card}" Margin="5,0,0,0"><StackPanel><TextBlock Text="Cartelle nuove" Foreground="#66737F" /><TextBlock x:Name="ImportMetricExisting" Text="&#x2014;" FontSize="22" FontWeight="Bold" Foreground="#1F2933" /></StackPanel></Border>
                            </Grid>
                            <Border Grid.Row="1" Style="{StaticResource Card}" Margin="0" Padding="0">
                                <Grid>
                                    <Grid.RowDefinitions><RowDefinition Height="Auto" /><RowDefinition Height="*" /><RowDefinition Height="Auto" /></Grid.RowDefinitions>
                                    <Border Grid.Row="0" Background="#F8F8FA" BorderBrush="#E5E5EA" BorderThickness="0,0,0,1" Padding="14,10">
                                        <TextBlock x:Name="ImportIdentity" Text="Eseguire il dry-run per verificare identit&#xE0; e piano." Foreground="#66737F" FontSize="11" TextWrapping="Wrap" />
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
                                        <TextBlock x:Name="ImportPlanStatus" Text="Nessuna richiesta sar&#xE0; inviata finch&#xE9; non viene avviato il dry-run." Foreground="#8A5A00" FontSize="11" TextWrapping="Wrap" />
                                    </Border>
                                </Grid>
                            </Border>
                            <Grid Grid.Row="2" Margin="0,12,0,0">
                                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto" /><ColumnDefinition Width="*" /><ColumnDefinition Width="260" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                                <Button x:Name="ImportBackButton" Content="&#x2190;  Torna alla revisione" Style="{StaticResource SecondaryButton}" />
                                <TextBlock x:Name="ConfirmationHint" Grid.Column="1" Text="Prima esegui il dry-run." Foreground="#66737F" FontSize="11" VerticalAlignment="Center" Margin="14,0" TextWrapping="Wrap" />
                                <TextBox x:Name="ImportConfirmation" Grid.Column="2" IsEnabled="False" ToolTip="Digita la frase di conferma esatta" Margin="6,0" />
                                <Button x:Name="ExecuteImportButton" Grid.Column="3" Content="Importa in Passbolt" Style="{StaticResource PrimaryButton}" IsEnabled="False" Margin="8,0,0,0" />
                            </Grid>
                        </Grid>
                    </TabItem>
                    <TabItem Header="Recupero import interrotto">
                        <Grid Margin="8,10,8,8">
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
                                    <Grid Grid.Row="1" Margin="0,10,0,0">
                                        <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions>
                                        <Grid.RowDefinitions><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /></Grid.RowDefinitions>
                                        <Border Grid.Row="0" Grid.Column="0" Style="{StaticResource Card}" Margin="0,0,5,5"><StackPanel><TextBlock Text="Operazioni verificate" Foreground="#66737F" FontSize="11" /><TextBlock x:Name="RecoveryMetricVerified" Text="&#x2014;" FontSize="20" FontWeight="Bold" Foreground="#1F2933" /></StackPanel></Border>
                                        <Border Grid.Row="0" Grid.Column="1" Style="{StaticResource Card}" Margin="5,0,0,5"><StackPanel><TextBlock Text="Gi&#xE0; riuscite" Foreground="#66737F" FontSize="11" /><TextBlock x:Name="RecoveryMetricRemoteSuccess" Text="&#x2014;" FontSize="20" FontWeight="Bold" Foreground="#16875D" /></StackPanel></Border>
                                        <Border Grid.Row="1" Grid.Column="0" Style="{StaticResource Card}" Margin="0,5,5,0"><StackPanel><TextBlock Text="Da applicare" Foreground="#66737F" FontSize="11" /><TextBlock x:Name="RecoveryMetricNotApplied" Text="&#x2014;" FontSize="20" FontWeight="Bold" Foreground="#B7791F" /></StackPanel></Border>
                                        <Border Grid.Row="1" Grid.Column="1" Style="{StaticResource Card}" Margin="5,5,0,0"><StackPanel><TextBlock Text="Conflitti" Foreground="#66737F" FontSize="11" /><TextBlock x:Name="RecoveryMetricConflicts" Text="&#x2014;" FontSize="20" FontWeight="Bold" Foreground="#C43D4B" /></StackPanel></Border>
                                    </Grid>
                                    <Border Grid.Row="2" Background="#EAF8F0" BorderBrush="#CAEAD8" BorderThickness="1" CornerRadius="12" Padding="14,10" Margin="0,10,0,0">
                                        <TextBlock x:Name="RecoverySafetyStatus" Text="Nessuna cancellazione, spostamento o sovrascrittura viene pianificata dal recupero." Foreground="#248A3D" FontSize="11" TextWrapping="Wrap" />
                                    </Border>
                                </Grid>
                            </Grid>
                            <Grid Grid.Row="2" Margin="0,12,0,0">
                                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto" /><ColumnDefinition Width="*" /><ColumnDefinition Width="245" /><ColumnDefinition Width="Auto" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                                <Button x:Name="RecoveryBackButton" Content="&#x2190;  Torna alla revisione" Style="{StaticResource SecondaryButton}" />
                                <TextBlock x:Name="RecoveryConfirmationHint" Grid.Column="1" Text="Seleziona un lotto recuperabile." Foreground="#66737F" FontSize="11" VerticalAlignment="Center" Margin="14,0" TextWrapping="Wrap" />
                                <TextBox x:Name="RecoveryConfirmation" Grid.Column="2" IsEnabled="False" ToolTip="Digita la frase RECUPERA N esatta" Margin="6,0" />
                                <Button x:Name="VerifyRecoveryButton" Grid.Column="3" Content="Verifica lotto" Style="{StaticResource SecondaryButton}" IsEnabled="False" Margin="8,0,0,0" />
                                <Button x:Name="ExecuteRecoveryButton" Grid.Column="4" Content="Recupera" Style="{StaticResource PrimaryButton}" IsEnabled="False" Margin="8,0,0,0" />
                            </Grid>
                        </Grid>
                    </TabItem>
                    <TabItem Header="Permessi esistenti">
                        <Grid Margin="8,10,8,8">
                            <Grid.RowDefinitions><RowDefinition Height="Auto" /><RowDefinition Height="*" /><RowDefinition Height="Auto" /></Grid.RowDefinitions>
                            <Border Grid.Row="0" Style="{StaticResource InfoBanner}">
                                <Grid>
                                    <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="150" /><ColumnDefinition Width="240" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                                    <StackPanel>
                                        <TextBlock Text="Permessi degli oggetti esistenti" FontWeight="SemiBold" Foreground="#1D1D1F" />
                                        <TextBlock Text="Consulta, simula e applica una ACL desiderata. Riduzioni e revoche richiedono una conferma rafforzata e il controllo degli utenti effettivamente coinvolti." Foreground="#355E85" FontSize="11" TextWrapping="Wrap" />
                                    </StackPanel>
                                    <ComboBox x:Name="AclTypeFilter" Grid.Column="1" Margin="10,0,0,0" SelectedIndex="0" ToolTip="Filtra per tipo di oggetto">
                                        <ComboBoxItem Content="Tutti gli oggetti" Tag="all" />
                                        <ComboBoxItem Content="Solo cartelle" Tag="folder" />
                                        <ComboBoxItem Content="Solo risorse" Tag="resource" />
                                    </ComboBox>
                                    <TextBox x:Name="AclSearchBox" Grid.Column="2" Margin="8,0,0,0" ToolTip="Cerca per nome, percorso o ID" />
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
                            <Grid Grid.Row="2" Margin="0,12,0,0">
                                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto" /><ColumnDefinition Width="*" /><ColumnDefinition Width="225" /><ColumnDefinition Width="Auto" /><ColumnDefinition Width="Auto" /><ColumnDefinition Width="Auto" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                                <Button x:Name="AclBackButton" Content="&#x2190;  Torna alla revisione" Style="{StaticResource SecondaryButton}" />
                                <TextBlock x:Name="AclViewerStatus" Grid.Column="1" Text="Avvia la sessione sicura, quindi leggi i permessi esistenti." Foreground="#66737F" FontSize="11" VerticalAlignment="Center" Margin="14,0" TextWrapping="Wrap" />
                                <TextBox x:Name="AclConfirmation" Grid.Column="2" IsEnabled="False" ToolTip="Digita la frase di conferma mostrata nel piano" Margin="6,0" />
                                <Button x:Name="AclPlanButton" Grid.Column="3" Content="Simula modifica..." Style="{StaticResource SecondaryButton}" IsEnabled="False" Margin="8,0,0,0" />
                                <Button x:Name="ApplyAclButton" Grid.Column="4" Content="Applica ACL" Style="{StaticResource PrimaryButton}" IsEnabled="False" Margin="8,0,0,0" />
                                <Button x:Name="RecoverAclButton" Grid.Column="5" Content="Recupera ACL..." Style="{StaticResource SecondaryButton}" IsEnabled="False" Margin="8,0,0,0" />
                                <Button x:Name="ManageAclJournalsButton" Grid.Column="6" Content="Gestisci journal..." Style="{StaticResource SecondaryButton}" Margin="8,0,0,0" ToolTip="Elenca, filtra, descrive e archivia i journal ACL locali senza cancellarli" />
                            </Grid>
                        </Grid>
                    </TabItem>
                </TabControl>
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
$PassboltUrl = Get-Control "PassboltUrl"
$DetectedFingerprint = Get-Control "DetectedFingerprint"
$VerifyButton = Get-Control "VerifyButton"
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
$PrepareImportButton = Get-Control "PrepareImportButton"
$ImportPage = Get-Control "ImportPage"
$ImportSummary = Get-Control "ImportSummary"
$ImportModeTabs = Get-Control "ImportModeTabs"
$PrivateKeyPath = Get-Control "PrivateKeyPath"
$BrowseKeyButton = Get-Control "BrowseKeyButton"
$KeyPassphrase = Get-Control "KeyPassphrase"
$MfaTotpCode = Get-Control "MfaTotpCode"
$ImportSessionButton = Get-Control "ImportSessionButton"
$DestinationMode = Get-Control "DestinationMode"
$DestinationFolder = Get-Control "DestinationFolder"
$ConfigureClientMappingsButton = Get-Control "ConfigureClientMappingsButton"
$PermissionModeStatus = Get-Control "PermissionModeStatus"
$ConfigurePermissionsButton = Get-Control "ConfigurePermissionsButton"
$FolderFormat = Get-Control "FolderFormat"
$ResourceFormat = Get-Control "ResourceFormat"
$DryRunButton = Get-Control "DryRunButton"
$ImportMetricSelected = Get-Control "ImportMetricSelected"
$ImportMetricCreate = Get-Control "ImportMetricCreate"
$ImportMetricDuplicates = Get-Control "ImportMetricDuplicates"
$ImportMetricExisting = Get-Control "ImportMetricExisting"
$ImportIdentity = Get-Control "ImportIdentity"
$ImportPlanGrid = Get-Control "ImportPlanGrid"
$ImportPlanStatus = Get-Control "ImportPlanStatus"
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
$script:InventoryResult = $null
$script:InventoryFolder = ""
$script:AllInventoryRows = @()
$script:ReviewResult = $null
$script:AllReviewRows = @()
$script:ReviewFilePasswords = @{}
$script:ReviewPasswordsVisible = $false
$script:UpdatingReviewPasswordToggle = $false
$script:ImportCandidates = @()
$script:ImportSecretOverrides = @{}
$script:ImportSourceFilePasswords = @{}
$script:ImportPlan = $null
$script:ImportPlanKeyPath = ""
$script:ImportCompleted = $false
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
$script:CurrentPage = "Configuration"

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

function Update-Ui {
    [System.Windows.Forms.Application]::DoEvents()
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
    [int]$TimeoutMilliseconds = 180000
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
        $OutputTask = $script:ImportSessionProcess.StandardOutput.ReadLineAsync()
        $PayloadBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Payload + "`n")
        $script:ImportSessionProcess.StandardInput.BaseStream.Write($PayloadBytes, 0, $PayloadBytes.Length)
        $script:ImportSessionProcess.StandardInput.BaseStream.Flush()
        if (-not $OutputTask.Wait($TimeoutMilliseconds)) {
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
        if ($null -eq $Envelope -or -not ($Envelope.PSObject.Properties.Name -contains "ok")) {
            throw "La sessione sicura locale ha restituito una struttura inattesa."
        }
        $script:ImportSessionLastActivityUtc = [DateTime]::UtcNow
        return $Envelope
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

function Update-ImportSessionState {
    $Active = Test-ImportSessionActive
    $PrivateKeyPath.IsEnabled = -not $Active
    $BrowseKeyButton.IsEnabled = -not $Active
    $KeyPassphrase.IsEnabled = -not $Active
    $MfaTotpCode.IsEnabled = -not $Active
    if ($Active) {
        $ImportSessionButton.Content = "Chiudi sessione"
        $ImportSessionButton.IsEnabled = $true
        $DryRunButton.IsEnabled = ($script:ConnectionVerified -and $script:ImportCandidates.Count -gt 0 -and $script:ImportSessionRoot -eq $script:InventoryFolder -and $null -eq $script:RecoveryPlan)
        if ($null -eq $script:ImportPlan) { $ImportIdentity.Text = Get-ImportSessionIdentityText }
    } else {
        $ImportSessionButton.Content = "Avvia sessione"
        $PreparedCandidateCount = [Math]::Max($script:ImportCandidates.Count, $script:RecoveryCandidates.Count)
        $ImportSessionButton.IsEnabled = ($script:ConnectionVerified -and $PreparedCandidateCount -gt 0 -and (Test-Path -LiteralPath $script:InventoryFolder -PathType Container))
        $DryRunButton.IsEnabled = $false
        if ($null -eq $script:ImportPlan) { $ImportIdentity.Text = "Avviare la sessione sicura per verificare identita' e piano." }
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
    $SessionId = $script:ImportSessionId
    if ($null -ne $Process) {
        try {
            if (-not $Process.HasExited -and $SessionId) {
                $CloseRequest = [pscustomobject][ordered]@{
                    command = "session-close"
                    session_id = $SessionId
                }
                try { [void](Invoke-ImportSessionJson $CloseRequest 10000) } catch {}
            }
            try { $Process.StandardInput.Close() } catch {}
            if (-not $Process.HasExited -and -not $Process.WaitForExit(10000)) {
                try { $Process.Kill() } catch {}
                try { [void]$Process.WaitForExit(5000) } catch {}
            }
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
        [System.Windows.MessageBox]::Show("La connessione Passbolt non e' verificata. Tornare alla configurazione.", "Connessione non verificata", "OK", "Warning") | Out-Null
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
    $OpenRequest = $null
    $ImportSessionButton.IsEnabled = $false
    $ImportPlanStatus.Text = "Apertura della sessione autenticata in corso..."
    Add-Activity "Avvio sessione autenticata GPGAuth per il workflow di importazione."
    Update-Ui
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
        $Envelope = Invoke-ImportSessionJson $OpenRequest
        if (-not [bool]$Envelope.ok) { throw (Get-SecureErrorMessage $Envelope) }
        if (-not [string]$Envelope.result.session_id) { throw "La sessione autenticata non ha restituito un identificatore valido." }
        $script:ImportSessionId = [string]$Envelope.result.session_id
        $script:ImportSessionInfo = $Envelope.result
        $script:ImportSessionRoot = $script:InventoryFolder
        $script:ImportSessionKeyPath = $KeyPath
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
        if ($null -ne $OpenRequest) {
            $OpenRequest.passphrase = $null
            $OpenRequest.mfa_totp = $null
        }
        $OpenRequest = $null
        $Passphrase = $null
        $MfaCode = $null
        $KeyPassphrase.Clear()
        $MfaTotpCode.Clear()
        Update-ImportSessionState
    }
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
                    $Message += " Verificare la sincronizzazione automatica di data, ora e fuso orario di Windows."
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

    $Envelope = $null
    try {
        $Envelope = Invoke-SecureJsonProcess $PythonExecutable @($ImportScript, "--reconciliation-describe") ([pscustomobject]@{
            batch_id = [string]$Selected.BatchId
        }) 30000
        if (-not [bool]$Envelope.ok) { throw (Get-SecureErrorMessage $Envelope) }
        $Details = $Envelope.result
        if ([string]$Details.batch_id -ne [string]$Selected.BatchId -or [string]$Details.status -ne "recovery_required") {
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
    } catch {
        Clear-RecoveryCandidateState
        $RecoveryStatus.Text = "Associazione del lotto non riuscita: $($_.Exception.Message)"
        $RecoveryConfirmationHint.Text = "Aggiorna l'elenco e riprova."
    } finally {
        $Envelope = $null
        Update-ImportSessionState
    }
}

function Refresh-RecoveryBatches([switch]$Quiet) {
    if ($null -ne $script:RecoveryPlan) { return }
    $PreviousBatchId = if ($null -ne $RecoveryBatchesGrid.SelectedItem) { [string]$RecoveryBatchesGrid.SelectedItem.BatchId } else { "" }
    $RefreshRecoveryButton.IsEnabled = $false
    try {
        $Envelope = Invoke-PythonJson $ImportScript @("--reconciliation-list")
        if (-not [bool]$Envelope.ok) { throw (Get-SecureErrorMessage $Envelope) }
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
        $script:UpdatingRecoverySelection = $true
        try {
            $RecoveryBatchesGrid.ItemsSource = $script:RecoveryBatches
            $RecoveryBatchesGrid.SelectedItem = @($script:RecoveryBatches | Where-Object { [string]$_.BatchId -eq $PreviousBatchId }) | Select-Object -First 1
        } finally {
            $script:UpdatingRecoverySelection = $false
        }
        if ($null -eq $RecoveryBatchesGrid.SelectedItem -and $script:RecoveryBatches.Count -gt 0) {
            $RecoveryBatchesGrid.SelectedIndex = 0
        } else {
            Set-RecoveryBatchSelection
        }
        if (-not $Quiet) { Add-Activity "Registri locali aggiornati: $($script:RecoveryBatches.Count) lotti attivi; nessun documento o segreto letto." }
    } catch {
        $script:RecoveryBatches = @()
        $RecoveryBatchesGrid.ItemsSource = $null
        Clear-RecoveryCandidateState
        Reset-RecoveryPlan "Elenco dei registri non disponibile: $($_.Exception.Message)"
        if (-not $Quiet) { Add-Activity "Aggiornamento registri non riuscito: $($_.Exception.Message)" }
    } finally {
        Update-RecoveryActionState
    }
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
    $ArchiveRecoveryButton.IsEnabled = $false
    try {
        $Envelope = Invoke-SecureJsonProcess $PythonExecutable @($ImportScript, "--reconciliation-archive") ([pscustomobject]@{
            batch_id = $BatchId
            expected_status = $Status
            confirmation = "ARCHIVIA $BatchId"
        }) 30000
        if (-not [bool]$Envelope.ok) { throw (Get-SecureErrorMessage $Envelope) }
        Clear-RecoveryCandidateState
        Reset-RecoveryPlan "Lotto archiviato senza cancellarne l'evidenza locale."
        Add-Activity "Registro locale $BatchId archiviato dallo stato $Status; nessuna evidenza eliminata."
        Refresh-RecoveryBatches -Quiet
        [System.Windows.MessageBox]::Show("Lotto archiviato correttamente. Il journal e' stato spostato, non cancellato.", "Archiviazione completata", "OK", "Information") | Out-Null
    } catch {
        Add-Activity "Archiviazione del lotto non riuscita: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Archiviazione non riuscita", "OK", "Error") | Out-Null
    } finally {
        Update-RecoveryActionState
    }
}

function Reset-ImportPlan([string]$Status = "Eseguire il dry-run per preparare un nuovo piano.") {
    $script:ImportPlan = $null
    $script:ImportPlanKeyPath = ""
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

function Get-AuthenticatedPermissionCatalog {
    if (-not (Test-ImportSessionActive)) {
        throw "Avviare prima la sessione autenticata Passbolt."
    }
    $Envelope = Invoke-ImportSessionJson ([pscustomobject][ordered]@{
        command = "session-permissions"
        session_id = $script:ImportSessionId
    })
    if (-not [bool]$Envelope.ok) { throw (Get-SecureErrorMessage $Envelope) }
    if ([string]$Envelope.result.command -ne "permission-catalog") {
        throw "Passbolt non ha restituito un catalogo permessi valido."
    }
    $script:PermissionCatalog = @($Envelope.result.entries)
    $script:PermissionCatalogSessionId = $script:ImportSessionId
    return $Envelope.result
}

function Show-PermissionEditor(
    [switch]$BuildOnly,
    [switch]$AclPlanMode,
    [object[]]$InitialPermissions = @(),
    [string]$TargetPath = ""
) {
    $CatalogResult = $null
    if ($BuildOnly) {
        $CatalogResult = [pscustomobject]@{
            entries = @($script:PermissionCatalog)
            owner = if ($null -ne $script:ImportSessionInfo) { $script:ImportSessionInfo.user } else { $null }
        }
    } else {
        try {
            $CatalogResult = Get-AuthenticatedPermissionCatalog
        } catch {
            [System.Windows.MessageBox]::Show($_.Exception.Message, "Permessi non disponibili", "OK", "Error") | Out-Null
            return
        }
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
    if (-not (Test-ImportSessionActive)) {
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

function Invoke-AclDryRun {
    Update-AclPlanActionState
    if (-not $AclPlanButton.IsEnabled) {
        [System.Windows.MessageBox]::Show([string]$AclPlanButton.ToolTip, "Dry-run ACL non disponibile", "OK", "Warning") | Out-Null
        return
    }
    $Selected = $AclObjectsGrid.SelectedItem
    $Raw = $Selected.Raw
    $InitialPermissions = @($Raw.permissions | Where-Object { -not [bool]$_.current_user } | ForEach-Object {
        [pscustomobject][ordered]@{
            aro = [string]$_.subject_kind
            aro_foreign_key = [string]$_.subject_id
            type = [int]$_.permission_type
        }
    })
    $EditorResult = Show-PermissionEditor -AclPlanMode -InitialPermissions $InitialPermissions -TargetPath ([string]$Raw.path)
    if ($null -eq $EditorResult) { return }
    Reset-AclPlan "Rilettura dello stato remoto e calcolo del confronto prima/dopo in corso..."
    $AclPlanButton.IsEnabled = $false
    $AclViewerStatus.Text = "Calcolo autenticato del piano ACL read-only in corso..."
    Add-Activity "Avvio dry-run ACL read-only per $([string]$Raw.object_type) $([string]$Raw.object_id)."
    Update-Ui
    $CloseSessionForError = $false
    try {
        $Envelope = Invoke-ImportSessionJson ([pscustomobject][ordered]@{
            command = "session-acl-plan"
            session_id = $script:ImportSessionId
            object_type = [string]$Raw.object_type
            object_id = [string]$Raw.object_id
            desired_permissions = @($EditorResult.Entries)
        }) 120000
        if (-not [bool]$Envelope.ok) {
            $CloseSessionForError = Test-TerminalImportSessionError $Envelope
            throw (Get-SecureErrorMessage $Envelope)
        }
        Set-AclPlanResult $Envelope.result
        $AclViewerStatus.Text = "Piano ACL calcolato su uno snapshot remoto fresco. Richieste di scrittura inviate: 0."
        Add-Activity "Dry-run ACL completato: $([int]$Envelope.result.change_count) modifiche classificate, 0 richieste di scrittura."
    } catch {
        Reset-AclPlan "Dry-run ACL non riuscito. Nessuna modifica e' stata applicata."
        $AclViewerStatus.Text = "Dry-run ACL non riuscito: $($_.Exception.Message)"
        Add-Activity "Dry-run ACL non riuscito: $($_.Exception.Message)"
        if ($CloseSessionForError -or -not (Test-ImportSessionActive)) {
            Stop-ImportSession "" $false
        }
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Piano ACL non disponibile", "OK", "Error") | Out-Null
    } finally {
        Update-AclPlanActionState
    }
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
        $Decision = [System.Windows.MessageBox]::Show(
            "ATTENZIONE: questa operazione riduce accessi esistenti.`n`nOggetto: $([string]$Plan.object.path)`nRiduzioni: $([int]$Counts.downgrade)`nRevoche: $([int]$Counts.revoke)`nUtenti effettivi con accesso ridotto: $([int]$Effective.downgrade)`nUtenti effettivi che perderanno accesso: $([int]$Effective.loss)`n`nIl proprietario autenticato resterà Owner. Continuare?",
            "Conferma modifica ACL restrittiva",
            "YesNo",
            "Warning"
        )
        if ($Decision -ne [System.Windows.MessageBoxResult]::Yes) {
            Add-Activity "Applicazione ACL restrittiva annullata prima della scrittura."
            return
        }
    }
    $ApplyAclButton.IsEnabled = $false
    $AclPlanButton.IsEnabled = $false
    $AclConfirmation.IsEnabled = $false
    $AclViewerStatus.Text = "Rilettura dello stato remoto, simulazione e applicazione ACL in corso..."
    Add-Activity "Avvio applicazione ACL $([string]$Plan.apply_mode) vincolata al piano $([string]$Plan.plan_digest)."
    Update-Ui
    $CloseSessionForError = $false
    $Envelope = $null
    try {
        $Envelope = Invoke-ImportSessionJson ([pscustomobject][ordered]@{
            command = "session-acl-apply"
            session_id = $script:ImportSessionId
            plan_id = [string]$Plan.plan_id
            object_state_digest = [string]$Plan.object_state_digest
            desired_acl_digest = [string]$Plan.desired_acl_digest
            directory_state_digest = [string]$Plan.directory_state_digest
            plan_digest = [string]$Plan.plan_digest
            confirmation = [string]$AclConfirmation.Text
        }) 180000
        if (-not [bool]$Envelope.ok) {
            $CloseSessionForError = Test-TerminalImportSessionError $Envelope
            throw (Get-SecureErrorMessage $Envelope)
        }
        $Result = $Envelope.result
        Add-Activity "ACL applicata: $([int]$Result.permission_change_count) modifiche, $([int]$Result.added_user_count) utenti aggiunti, $([int]$Result.removed_user_count) utenti rimossi. Journal $([string]$Result.acl_batch_id) completato."
        [System.Windows.MessageBox]::Show(
            "ACL applicata correttamente.`n`nModifiche inviate: $([int]$Result.permission_change_count)`nNuovi destinatari del segreto: $([int]$Result.added_user_count)`nUtenti effettivi rimossi: $([int]$Result.removed_user_count)`nModifiche restrittive: $([int]$Result.restrictive_change_count)`nJournal: $([string]$Result.acl_batch_id)",
            "ACL applicata",
            "OK",
            "Information"
        ) | Out-Null
        Refresh-ExistingAclCatalog
    } catch {
        $BatchId = if ($null -ne $Envelope -and $null -ne $Envelope.error -and $null -ne $Envelope.error.details) { [string]$Envelope.error.details.acl_batch_id } else { "" }
        Reset-AclPlan "Applicazione ACL non completata. Non ripetere il dry-run: usare Recupera ACL per verificare lo stato remoto."
        $AclViewerStatus.Text = "Applicazione ACL non completata: $($_.Exception.Message)"
        Add-Activity "Applicazione ACL non completata. Journal da verificare: $BatchId. $($_.Exception.Message)"
        if ($CloseSessionForError -or -not (Test-ImportSessionActive)) {
            Stop-ImportSession "" $false
        }
        $JournalText = if ($BatchId) { "`n`nJournal ACL: $BatchId`nUsare Recupera ACL prima di qualsiasi nuovo tentativo." } else { "" }
        [System.Windows.MessageBox]::Show("$($_.Exception.Message)$JournalText", "Applicazione ACL non completata", "OK", "Error") | Out-Null
    } finally {
        Update-AclPlanActionState
        Update-AclApplyActionState
    }
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
    $GetSelected = {
        if ($Grid.SelectedRows.Count -eq 0) { return $null }
        return $Grid.SelectedRows[0].Tag
    }
    $StatusText = {
        param([string]$Value)
        switch ($Value) {
            "recovery_required" { return "Recuperabile" }
            "complete" { return "Completo" }
            "truncated" { return "Troncato" }
            "corrupt" { return "Corrotto" }
            default { return "Sconosciuto" }
        }
    }
    $TypeText = {
        param([string]$Value)
        if ($Value -eq "folder") { return "Cartella" }
        if ($Value -eq "resource") { return "Risorsa" }
        return [string][char]0x2014
    }
    $ModeText = {
        param([string]$Value)
        switch ($Value) {
            "additive" { return "Additiva" }
            "mixed" { return "Mista" }
            "restrictive" { return "Restrittiva" }
            default { return [string][char]0x2014 }
        }
    }
    $ApplyFilters = {
        if ($State.Loading) { return }
        $State.Loading = $true
        $SelectedId = ""
        $SelectedBefore = & $GetSelected
        if ($null -ne $SelectedBefore) { $SelectedId = [string]$SelectedBefore.batch_id }
        $StatusValue = [string]$StatusFilter.SelectedItem.Value
        $TypeValue = [string]$TypeFilter.SelectedItem.Value
        $Days = [int]$DateFilter.SelectedItem.Days
        $Threshold = if ($Days -gt 0) { [DateTimeOffset]::UtcNow.AddDays(-$Days) } else { [DateTimeOffset]::MinValue }
        $Needle = $SearchBox.Text.Trim().ToLowerInvariant()
        $Grid.Rows.Clear()
        foreach ($Batch in @($State.Batches)) {
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
            $Index = $Grid.Rows.Add(@(
                $When,
                (& $StatusText ([string]$Batch.status)),
                (& $TypeText ([string]$Batch.object_type)),
                $(if ([string]$Batch.object_id) { [string]$Batch.object_id } else { [string][char]0x2014 }),
                (& $ModeText ([string]$Batch.apply_mode)),
                $Changes,
                [string]$Batch.batch_id
            ))
            $Grid.Rows[$Index].Tag = $Batch
            if ($SelectedId -and [string]$Batch.batch_id -eq $SelectedId) {
                $Grid.Rows[$Index].Selected = $true
                $Grid.CurrentCell = $Grid.Rows[$Index].Cells[0]
            }
        }
        $CountLabel.Text = "$($Grid.Rows.Count) journal visualizzati su $(@($State.Batches).Count) attivi"
        if ($Grid.Rows.Count -gt 0 -and $Grid.SelectedRows.Count -eq 0) {
            $Grid.Rows[0].Selected = $true
            $Grid.CurrentCell = $Grid.Rows[0].Cells[0]
        }
        $ArchiveButton.Enabled = $Grid.SelectedRows.Count -gt 0
        if ($Grid.Rows.Count -eq 0) { $Details.Text = "Nessun journal corrisponde ai filtri selezionati." }
        $State.Loading = $false
    }
    $LoadDetails = {
        if ($State.Loading) { return }
        $Selected = & $GetSelected
        $ArchiveButton.Enabled = $null -ne $Selected
        if ($null -eq $Selected) {
            $Details.Text = "Selezionare un journal."
            return
        }
        try {
            $Envelope = Invoke-SecureJsonProcess $PythonExecutable @($ImportScript, "--acl-reconciliation-describe") ([pscustomobject]@{
                batch_id = [string]$Selected.batch_id
            }) 30000
            if (-not [bool]$Envelope.ok) { throw (Get-SecureErrorMessage $Envelope) }
            $Item = $Envelope.result
            if ([string]$Item.batch_id -ne [string]$Selected.batch_id -or [string]$Item.status -ne [string]$Selected.status) {
                throw "Lo stato del journal ACL e' cambiato. Aggiornare l'elenco."
            }
            if ([string]$Item.status -eq "corrupt") {
                $Details.Text = "ID journal: $([string]$Item.batch_id)`r`nStato: Corrotto`r`n`r`nIl contenuto non e' attendibile e non viene interpretato. Il recupero automatico e' bloccato; e' disponibile soltanto l'archiviazione non distruttiva."
            } else {
                $Details.Text = @(
                    "ID journal: $([string]$Item.batch_id)",
                    "Stato: $(& $StatusText ([string]$Item.status))",
                    "Oggetto: $(& $TypeText ([string]$Item.object_type)) | $([string]$Item.object_id)",
                    "Modalita': $(& $ModeText ([string]$Item.apply_mode))",
                    "Modifiche: $([int]$Item.change_count) (aggiunte $([int]$Item.add_count), aumenti $([int]$Item.upgrade_count), riduzioni $([int]$Item.downgrade_count), revoche $([int]$Item.revoke_count))",
                    "Eventi: $([int]$Item.event_count) | applicazioni $([int]$Item.applied_operation_count) | errori $([int]$Item.failed_operation_count) | verifiche recupero $([int]$Item.recovery_verification_count)",
                    "Coda troncata: $(if ([bool]$Item.truncated_tail) { 'si' } else { 'no' })"
                ) -join "`r`n"
            }
        } catch {
            $Details.Text = "Dettaglio non disponibile: $($_.Exception.Message)"
        }
    }
    $Refresh = {
        if ($State.Loading) { return }
        $State.Loading = $true
        $RefreshButton.Enabled = $false
        $ArchiveButton.Enabled = $false
        $Details.Text = "Lettura dei metadati locali in corso..."
        try {
            $Envelope = Invoke-PythonJson $ImportScript @("--acl-reconciliation-list")
            if (-not [bool]$Envelope.ok) { throw (Get-SecureErrorMessage $Envelope) }
            $State.Batches = @($Envelope.result.batches)
            $State.Loading = $false
            & $ApplyFilters
            & $LoadDetails
            Add-Activity "Journal ACL aggiornati: $(@($State.Batches).Count) lotti attivi; nessun percorso, destinatario o segreto esposto."
        } catch {
            $State.Batches = @()
            $Grid.Rows.Clear()
            $CountLabel.Text = "Elenco non disponibile"
            $Details.Text = "Elenco dei journal ACL non disponibile: $($_.Exception.Message)"
            Add-Activity "Elenco journal ACL non disponibile: $($_.Exception.Message)"
        } finally {
            $State.Loading = $false
            $RefreshButton.Enabled = $true
        }
    }
    $Archive = {
        $Selected = & $GetSelected
        if ($null -eq $Selected) { return }
        $BatchId = [string]$Selected.batch_id
        $Status = [string]$Selected.status
        $Warning = "Il journal ACL $BatchId verra' spostato nell'archivio locale dello stato '$(& $StatusText $Status)'.`r`n`r`nNessuna evidenza verra' cancellata. Il lotto non comparira' piu nell'elenco attivo. Continuare?"
        if ([System.Windows.Forms.MessageBox]::Show($Warning, "Archivia journal ACL", "YesNo", "Warning") -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $Required = "ARCHIVIA ACL $BatchId"
        $Confirmation = Read-AclRecoveryConfirmation "L'operazione e' locale e non modifica Passbolt. Confermare lo spostamento non distruttivo del journal nello stato corrente." $Required "Conferma archiviazione ACL"
        if ($null -eq $Confirmation) { return }
        $ArchiveButton.Enabled = $false
        try {
            $Envelope = Invoke-SecureJsonProcess $PythonExecutable @($ImportScript, "--acl-reconciliation-archive") ([pscustomobject]@{
                batch_id = $BatchId
                expected_status = $Status
                confirmation = $Confirmation
            }) 30000
            if (-not [bool]$Envelope.ok) { throw (Get-SecureErrorMessage $Envelope) }
            if ([bool]$Envelope.result.deleted) { throw "Il backend ha restituito un esito di cancellazione non consentito." }
            Add-Activity "Journal ACL $BatchId archiviato dallo stato $Status; nessuna evidenza eliminata."
            [System.Windows.Forms.MessageBox]::Show("Journal ACL archiviato correttamente. L'evidenza e' stata spostata, non cancellata.", "Archiviazione completata", "OK", "Information") | Out-Null
            & $Refresh
        } catch {
            Add-Activity "Archiviazione journal ACL non riuscita: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Archiviazione non riuscita", "OK", "Error") | Out-Null
        } finally {
            $ArchiveButton.Enabled = $Grid.SelectedRows.Count -gt 0
        }
    }

    $StatusFilter.Add_SelectedIndexChanged({ & $ApplyFilters; & $LoadDetails })
    $TypeFilter.Add_SelectedIndexChanged({ & $ApplyFilters; & $LoadDetails })
    $DateFilter.Add_SelectedIndexChanged({ & $ApplyFilters; & $LoadDetails })
    $SearchBox.Add_TextChanged({ & $ApplyFilters; & $LoadDetails })
    $Grid.Add_SelectionChanged({ & $LoadDetails })
    $RefreshButton.Add_Click({ & $Refresh })
    $ArchiveButton.Add_Click({ & $Archive })

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
        & $ApplyFilters
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
        & $Refresh
        [void]$Dialog.ShowDialog()
    } finally {
        $Dialog.Dispose()
    }
}

function Invoke-AclRecovery {
    if (-not (Test-ImportSessionActive)) {
        [System.Windows.MessageBox]::Show("Avviare prima la sessione sicura Passbolt.", "Sessione non attiva", "OK", "Warning") | Out-Null
        return
    }
    try {
        $ListEnvelope = Invoke-PythonJson $ImportScript @("--acl-reconciliation-list")
        if (-not [bool]$ListEnvelope.ok) { throw (Get-SecureErrorMessage $ListEnvelope) }
    } catch {
        Add-Activity "Elenco journal ACL non disponibile: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Journal ACL non disponibili", "OK", "Error") | Out-Null
        return
    }
    $Pending = @($ListEnvelope.result.batches | Where-Object { [string]$_.status -eq "recovery_required" })
    if ($Pending.Count -eq 0) {
        [System.Windows.MessageBox]::Show("Non risultano journal ACL recuperabili. I journal completi, troncati o corrotti non vengono applicati automaticamente.", "Nessun recupero ACL", "OK", "Information") | Out-Null
        return
    }
    $Selected = Select-AclRecoveryBatch $Pending
    if ($null -eq $Selected) { return }
    $BatchId = [string]$Selected.batch_id
    $RecoverAclButton.IsEnabled = $false
    $AclViewerStatus.Text = "Verifica autenticata del journal ACL $BatchId in corso..."
    Add-Activity "Avvio verifica idempotente del journal ACL $BatchId."
    Update-Ui
    $Readiness = $null
    try {
        $ReadinessEnvelope = Invoke-ImportSessionJson ([pscustomobject][ordered]@{
            command = "session-acl-recovery-readiness"
            session_id = $script:ImportSessionId
            acl_batch_id = $BatchId
        }) 180000
        if (-not [bool]$ReadinessEnvelope.ok) { throw (Get-SecureErrorMessage $ReadinessEnvelope) }
        $Readiness = $ReadinessEnvelope.result
        $ResolutionText = if ([string]$Readiness.resolution -eq "remote_success") {
            "Passbolt contiene già la ACL attesa. Non verrà inviata alcuna scrittura; il journal sarà soltanto chiuso."
        } else {
            if ([bool]$Readiness.destructive_actions_planned) {
                "Passbolt contiene ancora esattamente lo snapshot originale. Il recupero ripeterà $([int]$Readiness.restrictive_change_count) riduzioni/revoche già registrate e richiede una conferma rafforzata."
            } else {
                "Passbolt contiene ancora esattamente lo snapshot originale. Verranno ripetute soltanto le modifiche ACL verificate."
            }
        }
        $Confirmation = Read-AclRecoveryConfirmation $ResolutionText ([string]$Readiness.confirmation_required)
        if ($null -eq $Confirmation) {
            [void](Invoke-ImportSessionJson ([pscustomobject][ordered]@{
                command = "session-acl-recovery-cancel"
                session_id = $script:ImportSessionId
                acl_batch_id = $BatchId
            }) 30000)
            $AclViewerStatus.Text = "Recupero ACL annullato dopo la verifica; nessuna scrittura applicata."
            return
        }
        if ([bool]$Readiness.destructive_actions_planned) {
            $Decision = [System.Windows.MessageBox]::Show(
                "Il recupero invierà nuovamente una modifica ACL restrittiva già registrata nel journal.`n`nRiduzioni/revoche: $([int]$Readiness.restrictive_change_count)`nIl bridge verificherà ancora snapshot, piano, directory e proprietario prima della scrittura.`n`nContinuare?",
                "Conferma recupero ACL restrittivo",
                "YesNo",
                "Warning"
            )
            if ($Decision -ne [System.Windows.MessageBoxResult]::Yes) {
                [void](Invoke-ImportSessionJson ([pscustomobject][ordered]@{
                    command = "session-acl-recovery-cancel"
                    session_id = $script:ImportSessionId
                    acl_batch_id = $BatchId
                }) 30000)
                $AclViewerStatus.Text = "Recupero ACL restrittivo annullato; nessuna scrittura applicata."
                return
            }
        }
        $ApplyEnvelope = Invoke-ImportSessionJson ([pscustomobject][ordered]@{
            command = "session-acl-recovery-apply"
            session_id = $script:ImportSessionId
            acl_batch_id = $BatchId
            recovery_id = [string]$Readiness.recovery_id
            recovery_plan_digest = [string]$Readiness.recovery_plan_digest
            confirmation = $Confirmation
        }) 180000
        if (-not [bool]$ApplyEnvelope.ok) { throw (Get-SecureErrorMessage $ApplyEnvelope) }
        $Result = $ApplyEnvelope.result
        $WriteText = if ([bool]$Result.remote_write_performed) { "La modifica ACL è stata applicata. Utenti effettivi rimossi: $([int]$Result.removed_user_count)." } else { "La modifica risultava già applicata; non è stata inviata alcuna scrittura." }
        Add-Activity "Journal ACL $BatchId riconciliato: $([string]$Result.resolution)."
        [System.Windows.MessageBox]::Show("$WriteText`n`nJournal chiuso: $BatchId", "Recupero ACL completato", "OK", "Information") | Out-Null
        Refresh-ExistingAclCatalog
    } catch {
        $AclViewerStatus.Text = "Recupero ACL non riuscito: $($_.Exception.Message)"
        Add-Activity "Recupero ACL $BatchId non riuscito: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Recupero ACL non completato", "OK", "Error") | Out-Null
    } finally {
        Update-AclApplyActionState
    }
}

function Refresh-ExistingAclCatalog {
    if (-not (Test-ImportSessionActive)) {
        [System.Windows.MessageBox]::Show("Avviare prima la sessione sicura Passbolt.", "Sessione non attiva", "OK", "Warning") | Out-Null
        return
    }
    $RefreshAclButton.IsEnabled = $false
    Reset-AclPlan "Aggiornamento del catalogo ACL in corso..."
    $AclViewerStatus.Text = "Lettura autenticata di cartelle, risorse e permessi in corso..."
    Add-Activity "Avvio lettura read-only delle ACL degli oggetti Passbolt esistenti."
    Update-Ui
    $CloseSessionForError = $false
    try {
        $Envelope = Invoke-ImportSessionJson ([pscustomobject][ordered]@{
            command = "session-acl-catalog"
            session_id = $script:ImportSessionId
        }) 120000
        if (-not [bool]$Envelope.ok) {
            $CloseSessionForError = Test-TerminalImportSessionError $Envelope
            throw (Get-SecureErrorMessage $Envelope)
        }
        Set-AclCatalogResult $Envelope.result
        Add-Activity "Catalogo ACL read-only caricato: $(@($script:AllAclObjectRows).Count) oggetti; nessuna richiesta di scrittura inviata."
    } catch {
        $script:AclCatalogSessionId = ""
        $script:AllAclObjectRows = @()
        $AclObjectsGrid.ItemsSource = $null
        $AclPermissionsGrid.ItemsSource = $null
        $AclObjectSummary.Text = "Seleziona un oggetto per visualizzare la relativa ACL."
        Reset-AclPlan "Catalogo ACL non disponibile. Nessun piano e' stato conservato."
        $AclViewerStatus.Text = "Lettura ACL non riuscita: $($_.Exception.Message)"
        Add-Activity "Lettura ACL non riuscita: $($_.Exception.Message)"
        if ($CloseSessionForError -or -not (Test-ImportSessionActive)) {
            Stop-ImportSession "" $false
        }
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Permessi non disponibili", "OK", "Error") | Out-Null
    } finally {
        Update-AclViewerState
    }
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
    $FolderFormat.IsEnabled = ($Mode -eq "client_folders")
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

function Read-ReviewSourceSecrets([object[]]$Rows) {
    $PendingRows = @($Rows | Where-Object {
        [bool]$_.SecretPresent -and -not [bool]$_.PasswordOverridden -and -not [bool]$_.SecretCachedFromSource
    })
    if ($PendingRows.Count -lt 1) { return }
    $Requests = @($PendingRows | ForEach-Object { Get-ReviewCandidateRequest $_ -ForReveal })
    $Envelope = $null
    $ById = @{}
    $SourceFilePasswords = @()
    $SecureRequest = $null
    try {
        $SourceFilePasswords = @(Get-ReviewSourceFilePasswordPayload $PendingRows)
        $SecureRequest = [pscustomobject]@{
            candidates = $Requests
            source_file_passwords = $SourceFilePasswords
        }
        $Envelope = Invoke-SecureJsonProcess $PythonExecutable @($ImportScript, "--reveal", "--root", $script:InventoryFolder) $SecureRequest
        if (-not [bool]$Envelope.ok) { throw (Get-SecureErrorMessage $Envelope) }
        foreach ($SecretItem in @($Envelope.result.secrets)) {
            $ById[[string]$SecretItem.candidate_id] = [string]$SecretItem.password
        }
        foreach ($Row in $PendingRows) {
            if (-not $ById.ContainsKey([string]$Row.CandidateId)) {
                throw "La password richiesta non e' stata restituita dalla lettura locale."
            }
            $Row.SecretValue = [string]$ById[[string]$Row.CandidateId]
            $Row.SecretCachedFromSource = $true
        }
        $ById.Clear()
    } finally {
        $ById.Clear()
        $Requests = $null
        foreach ($Entry in $SourceFilePasswords) { $Entry.password = $null }
        if ($null -ne $SecureRequest) { $SecureRequest.source_file_passwords = $null }
        $SourceFilePasswords = @()
        $SecureRequest = $null
        if ($null -ne $Envelope -and $null -ne $Envelope.result) {
            $Envelope.result.secrets = $null
        }
        $Envelope = $null
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
        try {
            Read-ReviewSourceSecrets $script:AllReviewRows
            $script:ReviewPasswordsVisible = $true
            Add-Activity "Visualizzazione temporanea delle password attivata; nessun valore segreto e' stato registrato."
        } catch {
            $script:ReviewPasswordsVisible = $false
            foreach ($Row in $script:AllReviewRows) {
                if (-not [bool]$Row.PasswordOverridden) {
                    $Row.SecretValue = ""
                    $Row.SecretCachedFromSource = $false
                }
            }
            $script:UpdatingReviewPasswordToggle = $true
            try { $ReviewPasswordToggle.IsChecked = $false } finally { $script:UpdatingReviewPasswordToggle = $false }
            [System.Windows.MessageBox]::Show($_.Exception.Message, "Password non disponibili", "OK", "Error") | Out-Null
        }
    } elseif (-not $Visible) {
        $script:ReviewPasswordsVisible = $false
        foreach ($Row in $script:AllReviewRows) {
            if (-not [bool]$Row.PasswordOverridden) {
                $Row.SecretValue = ""
                $Row.SecretCachedFromSource = $false
            }
        }
    }

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

function Show-ReviewCandidateEditor($Row = $null, [switch]$BuildOnly) {
    if ($null -eq $Row) {
        $Selected = @($ReviewCandidatesGrid.SelectedItems)
        if ($Selected.Count -ne 1) { return }
        $Row = $Selected[0]
    }
    if (-not $BuildOnly -and [bool]$Row.SecretPresent -and -not [bool]$Row.PasswordOverridden -and -not [bool]$Row.SecretCachedFromSource) {
        try {
            Read-ReviewSourceSecrets @($Row)
        } catch {
            [System.Windows.MessageBox]::Show($_.Exception.Message, "Password non disponibile", "OK", "Error") | Out-Null
            return
        }
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
    $PasswordText = New-Object System.Windows.Controls.TextBox
    $PasswordText.MaxLength = 65536
    $PasswordText.Text = [string]$Row.SecretValue
    $PasswordText.Visibility = "Collapsed"
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
        [bool]$script:ImportPlan.can_import -and
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
    Reset-ImportPlan $PreparationStatus
    $StepImportNumber.Foreground = Get-Brush "#007AFF"
    $StepImportText.Foreground = Get-Brush "#3A3A3C"
    Add-Activity "Preparazione importazione: $($script:ImportCandidates.Count) candidati, nessun segreto registrato."
    Update-ImportSessionState
    $ImportModeTabs.SelectedIndex = 0
    Show-Page "Import"
    Refresh-RecoveryBatches -Quiet
}

function Invoke-ImportReadiness {
    if (-not $script:ConnectionVerified -or -not $script:VerifiedUrl -or -not $script:VerifiedFingerprint) {
        [System.Windows.MessageBox]::Show("La connessione Passbolt non e' verificata. Tornare alla configurazione.", "Connessione non verificata", "OK", "Warning") | Out-Null
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

    Reset-ImportPlan "Controllo integrita' e dry-run nella sessione autenticata in corso..."
    $DryRunButton.IsEnabled = $false
    $ReadinessRequest = $null
    $ReadinessSourceFilePasswords = @()
    $Envelope = $null
    $CloseSessionForError = $false
    $RequestedResourceFormat = [string]$ResourceFormat.SelectedItem.Tag
    if ($RequestedResourceFormat -notin @("auto", "v4", "v5")) { $RequestedResourceFormat = "auto" }
    $RequestedFolderFormat = [string]$FolderFormat.SelectedItem.Tag
    if ($RequestedFolderFormat -notin @("auto", "v4", "v5")) { $RequestedFolderFormat = "auto" }
    $RequestedDestinationMode = [string]$DestinationMode.SelectedItem.Tag
    if ($RequestedDestinationMode -notin @("client_folders", "client_mapping", "direct_folder", "root")) { $RequestedDestinationMode = "client_folders" }
    $RequestedDestinationFolderId = if ($RequestedDestinationMode -eq "client_mapping") { "" } else { Get-SelectedDestinationFolderId }
    $RequestedClientDestinationMapping = if ($RequestedDestinationMode -eq "client_mapping") { @(Get-ClientDestinationMappingPayload) } else { @() }
    Add-Activity "Avvio dry-run nella sessione GPGAuth attiva (risorse $RequestedResourceFormat, cartelle $RequestedFolderFormat)."
    Update-Ui
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
        $Envelope = Invoke-ImportSessionJson $ReadinessRequest
        if (-not [bool]$Envelope.ok) {
            $CloseSessionForError = Test-TerminalImportSessionError $Envelope
            throw (Get-SecureErrorMessage $Envelope)
        }
        $Result = $Envelope.result
        $script:ImportPlan = $Result
        $script:ImportPlanKeyPath = $script:ImportSessionKeyPath
        Update-DestinationFolderOptions $Result.available_folders ([string]$Result.destination_folder_id)

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

        if ([bool]$Result.can_import -and [int]$Result.create_count -gt 0) {
            $ExpectedPhrase = "IMPORTA $([int]$Result.create_count)"
            $SharedFolderSummary = if ([int]$Result.create_shared_folder_count -gt 0) {
                $PermissionSource = if ([string]$Result.permission_mode -eq "custom") { "personalizzati" } else { "ereditati" }
                " Cartelle condivise da creare con permessi ${PermissionSource}: $([int]$Result.create_shared_folder_count)."
            } else { "" }
            $ReconciledFolderSummary = if ([int]$Result.reconcile_shared_folder_count -gt 0) {
                " Cartelle personali vuote da riconciliare con i permessi del contenitore: $([int]$Result.reconcile_shared_folder_count)."
            } else { "" }
            $SharingSummary = if ([int]$Result.shared_create_count -gt 0) {
                " Risorse condivise: $([int]$Result.shared_create_count); copie cifrate complessive: $([int]$Result.encrypted_secret_copy_count)."
            } else { "" }
            $ImportPlanStatus.Text = "Dry-run completato. Nessuna modifica eseguita; cartelle nuove: $($Result.create_folder_count), da riconciliare: $($Result.reconcile_shared_folder_count), cartelle riutilizzate: $($Result.reuse_folder_count).$SharedFolderSummary$ReconciledFolderSummary$SharingSummary Le cartelle Passbolt sono caricate: se cambi la destinazione, ripeti il dry-run."
            $ConfirmationHint.Text = "Sessione sicura attiva. Digita: $ExpectedPhrase"
            $ImportConfirmation.IsEnabled = $true
            Add-Activity "Dry-run completato: $($Result.create_count) risorse e $($Result.create_folder_count) cartelle da creare, $($Result.reconcile_shared_folder_count) cartelle da riconciliare, incluse $($Result.create_shared_folder_count) nuove condivise; $($Result.duplicate_count) duplicati nella destinazione."
        } elseif ([bool]$Result.can_import) {
            $ImportPlanStatus.Text = "Dry-run completato: tutti i candidati selezionati risultano gia' presenti."
            $ConfirmationHint.Text = "Nessuna nuova risorsa da creare."
            Add-Activity "Dry-run completato: nessuna nuova risorsa; $($Result.duplicate_count) duplicati esatti."
        } else {
            $ImportPlanStatus.Text = [string]$Result.unavailable_reason
            $ConfirmationHint.Text = "Scrittura bloccata dalle capacita' dichiarate dal server."
            Add-Activity "Dry-run completato; scrittura non disponibile per le capacita' dell'istanza."
        }
    } catch {
        $FailureMessage = [string]$_.Exception.Message
        if ($CloseSessionForError -or -not (Test-ImportSessionActive)) {
            Stop-ImportSession "" $false
        }
        Reset-ImportPlan "Dry-run non riuscito. Nessuna modifica e' stata eseguita."
        Add-Activity "Dry-run non riuscito: $FailureMessage"
        [System.Windows.MessageBox]::Show($FailureMessage, "Dry-run non riuscito", "OK", "Error") | Out-Null
    } finally {
        foreach ($Entry in $ReadinessSourceFilePasswords) { $Entry.password = $null }
        if ($null -ne $ReadinessRequest) { $ReadinessRequest.source_file_passwords = $null }
        $ReadinessSourceFilePasswords = @()
        $ReadinessRequest = $null
        Update-ImportSessionState
    }
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
            $SecretOverrides.Add([pscustomobject][ordered]@{
                candidate_id = $CandidateId
                password = [string]$script:ImportSecretOverrides[$CandidateId]
            })
        }
    }
    $CreateCandidates = @($script:ImportCandidates | Where-Object { [string]$_.candidate_id -in $CreateCandidateIds })
    $WriteSourceFilePasswords = @()
    try {
        $WriteSourceFilePasswords = @(Get-ImportSourceFilePasswordPayload $CreateCandidates)
    } catch {
        foreach ($Entry in $SecretOverrides) { $Entry.password = $null }
        $SecretOverrides.Clear()
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Password Excel non disponibile", "OK", "Error") | Out-Null
        return
    }
    $ExecuteImportButton.IsEnabled = $false
    $DryRunButton.IsEnabled = $false
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
    Update-Ui
    $Envelope = $null
    $CloseSessionForError = $false
    try {
        $Envelope = Invoke-ImportSessionJson $ExecuteRequest
        if (-not [bool]$Envelope.ok) {
            $CloseSessionForError = Test-TerminalImportSessionError $Envelope
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
                $Message += "`n`nRegistro locale del lotto: $([string]$Envelope.error.details.reconciliation_batch_id). Lo stato richiede una verifica autenticata prima di qualunque nuovo tentativo. Apri la scheda 'Recupero import interrotto' della fase 04 e associa la cartella sorgente corrente."
            }
            if ($CreatedBeforeFailure -gt 0 -or $CreatedFoldersBeforeFailure -gt 0) {
                $Message += "`n`nAttenzione: $CreatedFoldersBeforeFailure cartelle e $CreatedBeforeFailure risorse risultano create prima dell'errore. Usare il recupero guidato per riverificare lo stato; non verranno eliminate automaticamente."
            }
            if ($null -ne $Envelope.error.details -and [bool]$Envelope.error.details.folder_reconciliation_failed) {
                $Message += "`n`nLa cartella personale $($Envelope.error.details.existing_personal_folder_id) non e' stata riconciliata con i permessi del contenitore. Nessuna risorsa del cliente e' stata inserita al suo interno. Usare il recupero guidato per verificare lo stato corrente."
            } elseif ($null -ne $Envelope.error.details -and [bool]$Envelope.error.details.folder_sharing_failed) {
                $Message += "`n`nLa cartella $($Envelope.error.details.created_unshared_folder_id) e' stata creata ma i permessi ereditati non sono stati applicati. Al momento resta personale; nessuna risorsa del cliente e' stata inserita al suo interno. Usare il recupero guidato per riconciliare lo stato."
            } elseif ($null -ne $Envelope.error.details -and [bool]$Envelope.error.details.sharing_failed) {
                $Message += "`n`nLa risorsa $($Envelope.error.details.created_unshared_resource_id) e' stata creata ma la condivisione non e' stata applicata. Al momento resta personale e deve essere riconciliata dal recupero guidato prima di continuare."
            }
            throw $Message
        }
        $Result = $Envelope.result
        $script:ImportCompleted = $true
        $script:ImportPlan = $null
        foreach ($CandidateId in $CreateCandidateIds) {
            if ($script:ImportSecretOverrides.ContainsKey($CandidateId)) {
                $script:ImportSecretOverrides.Remove($CandidateId)
            }
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
        $ConfirmationHint.Text = "Importazione completata. La sessione resta attiva per il prossimo lotto."
        $ImportPlanStatus.Text = "Importazione completata: $($Result.created_folder_count) cartelle create, incluse $($Result.shared_created_folder_count) condivise, $($Result.reconciled_shared_folder_count) cartelle riconciliate e $($Result.created_count) risorse create, incluse $($Result.shared_created_count) condivise; $($Result.skipped_duplicate_count) duplicati saltati."
        foreach ($Row in @($ImportPlanGrid.ItemsSource)) {
            if ($Row.Action -eq "create") { $Row.ActionLabel = "Creata" }
        }
        $ImportPlanGrid.Items.Refresh()
        Add-Activity "Importazione completata: $($Result.created_folder_count) cartelle create, incluse $($Result.shared_created_folder_count) condivise, $($Result.reconciled_shared_folder_count) cartelle riconciliate e $($Result.created_count) risorse create, incluse $($Result.shared_created_count) condivise; $($Result.skipped_duplicate_count) duplicati saltati."
        if (-not [string]::IsNullOrWhiteSpace([string]$Result.reconciliation_batch_id)) {
            Add-Activity "Registro locale del lotto $([string]$Result.reconciliation_batch_id) completato."
        }
        Refresh-RecoveryBatches -Quiet
        [System.Windows.MessageBox]::Show("Importazione completata correttamente.`n`nCartelle create: $($Result.created_folder_count)`nCartelle condivise create: $($Result.shared_created_folder_count)`nCartelle personali riconciliate: $($Result.reconciled_shared_folder_count)`nCartelle riutilizzate: $($Result.reused_folder_count)`nRisorse create: $($Result.created_count)`nRisorse condivise: $($Result.shared_created_count)`nCopie cifrate complessive: $($Result.encrypted_secret_copy_count)`nDuplicati saltati: $($Result.skipped_duplicate_count)", "Importazione completata", "OK", "Information") | Out-Null
    } catch {
        $FailureMessage = [string]$_.Exception.Message
        if ($CloseSessionForError -or -not (Test-ImportSessionActive)) {
            Stop-ImportSession "" $false
        }
        Reset-ImportPlan "Importazione interrotta. Aprire la scheda di recupero e verificare il lotto autenticato prima di riprovare."
        Refresh-RecoveryBatches -Quiet
        Add-Activity "Importazione non completata: $FailureMessage"
        [System.Windows.MessageBox]::Show($FailureMessage, "Importazione non completata - v0.21.0", "OK", "Error") | Out-Null
    } finally {
        foreach ($Entry in $SecretOverrides) { $Entry.password = $null }
        foreach ($Entry in $WriteSourceFilePasswords) { $Entry.password = $null }
        if ($null -ne $ExecuteRequest) {
            $ExecuteRequest.secret_overrides = $null
            $ExecuteRequest.source_file_passwords = $null
        }
        $WriteSourceFilePasswords = @()
        $SecretOverrides = $null
        $ExecuteRequest = $null
        Update-ImportSessionState
    }
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
    $VerifyRecoveryButton.IsEnabled = $false
    $ReadinessRequest = $null
    $SourceFilePasswords = @()
    $Envelope = $null
    $CloseSessionForError = $false
    $BatchId = [string]$Selected.BatchId
    Add-Activity "Avvio verifica autenticata del lotto $BatchId."
    Update-Ui
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
        $Envelope = Invoke-ImportSessionJson $ReadinessRequest
        if (-not [bool]$Envelope.ok) {
            $CloseSessionForError = Test-TerminalImportSessionError $Envelope
            throw (Get-SecureErrorMessage $Envelope)
        }
        $Result = $Envelope.result
        if (
            [string]$Result.reconciliation_batch_id -ne $BatchId -or
            -not [bool]$Result.can_recover -or
            [bool]$Result.destructive_actions_planned -or
            [int]$Result.conflict_count -ne 0 -or
            [string]$Result.confirmation_required -ne "RECUPERA $([int]$Result.retry_action_count)" -or
            -not [string]$Result.recovery_id -or
            -not [string]$Result.recovery_plan_digest
        ) {
            $CloseSessionForError = $true
            throw "La verifica del recupero ha restituito un piano incoerente o non sicuro."
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
        $RecoveryConfirmation.IsEnabled = $true
        Add-Activity "Lotto $BatchId verificato: $([int]$Result.remote_success_count) esiti remoti confermati, $([int]$Result.retry_action_count) azioni idempotenti da applicare, nessun conflitto."
    } catch {
        $FailureMessage = [string]$_.Exception.Message
        if ($CloseSessionForError -or -not (Test-ImportSessionActive)) {
            Stop-ImportSession "" $false
        }
        Reset-RecoveryPlan "Verifica del lotto non riuscita. Nessuna azione di recupero e' stata applicata."
        Add-Activity "Verifica del lotto non riuscita: $FailureMessage"
        [System.Windows.MessageBox]::Show($FailureMessage, "Verifica recupero non riuscita", "OK", "Error") | Out-Null
    } finally {
        foreach ($Entry in $SourceFilePasswords) { $Entry.password = $null }
        if ($null -ne $ReadinessRequest) { $ReadinessRequest.source_file_passwords = $null }
        $SourceFilePasswords = @()
        $ReadinessRequest = $null
        Update-ImportSessionState
    }
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
            $SecretOverrides.Add([pscustomobject][ordered]@{
                candidate_id = $CandidateId
                password = [string]$script:RecoverySecretOverrides[$CandidateId]
            })
        }
    }

    $SourceFilePasswords = @()
    $ExecuteRequest = $null
    $Envelope = $null
    $CloseSessionForError = $false
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
        $ExecuteRecoveryButton.IsEnabled = $false
        $VerifyRecoveryButton.IsEnabled = $false
        Add-Activity "Avvio recupero confermato del lotto $BatchId con $RetryCount azioni idempotenti."
        Update-Ui
        $Envelope = Invoke-ImportSessionJson $ExecuteRequest
        if (-not [bool]$Envelope.ok) {
            $CloseSessionForError = Test-TerminalImportSessionError $Envelope
            throw (Get-SecureErrorMessage $Envelope)
        }
        $Result = $Envelope.result
        if (-not [bool]$Result.complete -or [bool]$Result.destructive_actions_performed) {
            $CloseSessionForError = $true
            throw "Il recupero non ha restituito una chiusura sicura e verificabile del lotto."
        }
        $script:RecoveryPlan = $null
        $RecoveryConfirmation.Text = ""
        $RecoveryConfirmation.IsEnabled = $false
        $RecoveryStatus.Text = "Recupero completato e journal chiuso."
        $RecoveryConfirmationHint.Text = "Il lotto completato puo' essere archiviato."
        Add-Activity "Recupero del lotto $BatchId completato: $([int]$Result.created_folder_count) cartelle create, $([int]$Result.reconciled_folder_count) riconciliate, $([int]$Result.created_count) risorse create e $([int]$Result.repaired_resource_count) condivisioni riparate."
        Refresh-RecoveryBatches -Quiet
        $ArchiveDecision = [System.Windows.MessageBox]::Show(
            "Recupero completato correttamente.`n`nCartelle create: $([int]$Result.created_folder_count)`nCartelle riconciliate: $([int]$Result.reconciled_folder_count)`nRisorse create: $([int]$Result.created_count)`nCondivisioni riparate: $([int]$Result.repaired_resource_count)`nOperazioni remote gia' riuscite: $([int]$Result.remote_success_count)`nAzioni distruttive: nessuna`n`nArchiviare ora il journal completato?",
            "Recupero completato",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Information
        )
        if ($ArchiveDecision -eq [System.Windows.MessageBoxResult]::Yes) {
            Invoke-ArchiveRecoveryBatch -AlreadyConfirmed
        }
    } catch {
        $FailureMessage = [string]$_.Exception.Message
        if ($CloseSessionForError -or -not (Test-ImportSessionActive)) {
            Stop-ImportSession "" $false
        }
        Reset-RecoveryPlan "Recupero interrotto. Aggiornare il lotto e ripetere la verifica autenticata; nessuna operazione distruttiva verra' tentata."
        Add-Activity "Recupero del lotto non completato: $FailureMessage"
        [System.Windows.MessageBox]::Show($FailureMessage, "Recupero non completato", "OK", "Error") | Out-Null
        Refresh-RecoveryBatches -Quiet
    } finally {
        foreach ($Entry in $SecretOverrides) { $Entry.password = $null }
        foreach ($Entry in $SourceFilePasswords) { $Entry.password = $null }
        if ($null -ne $ExecuteRequest) {
            $ExecuteRequest.secret_overrides = $null
            $ExecuteRequest.source_file_passwords = $null
        }
        $SecretOverrides = $null
        $SourceFilePasswords = @()
        $ExecuteRequest = $null
        Update-ImportSessionState
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

    $CanContinue = $script:ConnectionVerified -and $FolderIsValid
    $ContinueButton.IsEnabled = $CanContinue
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
    $PasswordText = New-Object System.Windows.Controls.TextBox
    $PasswordText.MaxLength = 1024
    $PasswordText.Visibility = "Collapsed"
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

function Invoke-SecureExcelReview([string[]]$Files, [hashtable]$Passwords) {
    $PasswordEntries = New-Object System.Collections.Generic.List[object]
    foreach ($RelativePath in @($Passwords.Keys | Sort-Object)) {
        $PasswordEntries.Add([pscustomobject][ordered]@{
            relative_path = [string]$RelativePath
            password = [string]$Passwords[$RelativePath]
        })
    }
    $Request = [pscustomobject]@{
        files = $Files
        file_passwords = $PasswordEntries.ToArray()
    }
    try {
        $Envelope = Invoke-SecureJsonProcess $PythonExecutable @($ReviewScript, "--secure-json", "--root", $script:InventoryFolder) $Request
        if (-not [bool]$Envelope.ok) { throw (Get-SecureErrorMessage $Envelope) }
        return $Envelope.result
    } finally {
        foreach ($Entry in $PasswordEntries) { $Entry.password = $null }
        $Request.file_passwords = $null
        $PasswordEntries.Clear()
        $Request = $null
    }
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
    $Arguments = New-Object System.Collections.Generic.List[string]
    $Arguments.Add("--root")
    $Arguments.Add($script:InventoryFolder)
    $Arguments.Add("--json")
    $SelectedFiles = New-Object System.Collections.Generic.List[string]
    foreach ($SelectedItem in $FilesGrid.SelectedItems) {
        $Arguments.Add("--file")
        $Arguments.Add([string]$SelectedItem.RelativePath)
        $SelectedFiles.Add([string]$SelectedItem.RelativePath)
    }

    $ReviewSelectionButton.IsEnabled = $false
    $ReviewSelectionButton.Content = "Analisi locale in corso..."
    Add-Activity "Avvio revisione locale di $SelectedCount file selezionati."
    Update-Ui
    $script:ReviewFilePasswords = @{}
    $ExcelPasswords = @{}
    try {
        $Result = Invoke-PythonJson $ReviewScript ($Arguments.ToArray())
        $PromptAttempts = 0
        while (@($Result.protected_excel_issues).Count -gt 0) {
            $PromptAttempts++
            if ($PromptAttempts -gt 10) {
                throw "Impossibile completare la lettura dei file Excel protetti dopo troppi tentativi."
            }
            foreach ($Issue in @($Result.protected_excel_issues)) {
                $RelativePath = [string]$Issue.relative_path
                $IssueStatus = [string]$Issue.status
                if ($IssueStatus -eq "reader_unavailable") {
                    throw "Il lettore dei file Excel cifrati non e' installato. Eseguire: python -m pip install -r requirements.txt"
                }
                if ($IssueStatus -notin @("password_required", "password_rejected")) {
                    throw "Il file Excel protetto $RelativePath non puo essere letto in sicurezza."
                }
                $Password = Show-ExcelPasswordDialog $RelativePath -Retry:($IssueStatus -eq "password_rejected")
                if ($null -eq $Password) {
                    $ExcelPasswords.Clear()
                    Add-Activity "Revisione annullata durante la richiesta della password di un file Excel."
                    return
                }
                $ExcelPasswords[$RelativePath] = [string]$Password
                $Password = $null
            }
            Add-Activity "Nuovo tentativo di lettura locale di $($ExcelPasswords.Count) file Excel protetti; nessuna password e' stata registrata."
            $Result = Invoke-SecureExcelReview ($SelectedFiles.ToArray()) $ExcelPasswords
        }
        $script:ReviewFilePasswords = @{}
        foreach ($RelativePath in $ExcelPasswords.Keys) {
            $script:ReviewFilePasswords[[string]$RelativePath] = [string]$ExcelPasswords[$RelativePath]
        }
        $ExcelPasswords.Clear()
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
                }
                Update-ReviewRowState $Row
                $ReviewRows.Add($Row)
            }
        }
        $script:ReviewResult = $Result
        $script:AllReviewRows = $ReviewRows.ToArray()
        Reset-ImportWorkflow
        $ReviewMetricFiles.Text = "$($Result.analyzed_files)/$($Result.selected_files)"
        Update-ReviewMetrics
        $ReviewSummary.Text = "Revisione locale completata $(Get-Date -Format 'dd/MM/yyyy HH:mm')"
        Set-ReviewFilters
        Apply-ReviewFilters

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
        Show-Page "Review"
    } catch {
        $script:ReviewFilePasswords = @{}
        $ExcelPasswords.Clear()
        Add-Activity "Revisione non riuscita: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Revisione non riuscita", "OK", "Error") | Out-Null
    } finally {
        $ExcelPasswords.Clear()
        Update-ReviewSelectionState
    }
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
    $script:ReviewFilePasswords = @{}
    Reset-ImportWorkflow
    $ReviewCandidatesGrid.ItemsSource = $null
    $StepReviewNumber.Foreground = Get-Brush "#8E8E93"
    $StepReviewText.Foreground = Get-Brush "#8E8E93"
    $RefreshButton.IsEnabled = $false
    $ExportButton.IsEnabled = $false
    $InventoryRoot.Text = "Analisi dei metadati in corso: $Folder"
    $FilesGrid.ItemsSource = $null
    $FilterStatus.Text = "Analisi in corso..."
    Add-Activity "Avvio inventario metadati."
    Update-Ui

    try {
        $Result = Invoke-PythonJson $InventoryScript @("--inventory", $Folder, "--json")
        $script:InventoryResult = $Result
        $script:InventoryFolder = $Folder
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
        # Windows PowerShell 5.1 throws "Argument types do not match" when a
        # generic List[object] is expanded with @($RowList). ToArray() avoids
        # that legacy binder bug and gives the DataGrid a regular object array.
        $script:AllInventoryRows = $RowList.ToArray()
        $MetricClients.Text = [string]$Result.client_folders
        $MetricFiles.Text = [string]$Result.supported_files
        $MetricSize.Text = Format-Size ([long]$Result.supported_bytes)
        $MetricIgnored.Text = [string]$Result.ignored_files
        $InventoryRoot.Text = "Cartella: $($Result.root) $([char]0x2022) inventario aggiornato $(Get-Date -Format 'dd/MM/yyyy HH:mm')"
        Set-InventoryFilters $Result
        Apply-InventoryFilters

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

        $ExportButton.IsEnabled = $true
        Add-Activity "Inventario completato: $($Result.client_folders) clienti, $($Result.supported_files) file supportati, $($Result.ignored_files) ignorati."
    } catch {
        $script:InventoryResult = $null
        $script:AllInventoryRows = @()
        $InventoryRoot.Text = "Inventario non riuscito"
        $FilterStatus.Text = "0 file"
        Add-Activity "Inventario non riuscito: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Inventario non riuscito", "OK", "Error") | Out-Null
    } finally {
        $RefreshButton.IsEnabled = $true
        Update-ReviewSelectionState
    }
}

$PassboltUrl.Add_TextChanged({
    if ($script:VerifiedUrl -and $PassboltUrl.Text.Trim() -ne $script:VerifiedUrl) {
        if (Test-ImportSessionActive) {
            Stop-ImportSession "Sessione chiusa perche' l'URL Passbolt e' stato modificato." $false
        }
        $script:ConnectionVerified = $false
        $script:VerifiedUrl = ""
        $script:VerifiedFingerprint = ""
        $DetectedFingerprint.Text = "Non ancora rilevata"
        Reset-ImportPlan "URL Passbolt modificato. Ripetere connessione e dry-run."
        $script:ClientDestinationMap = @{}
        $script:PermissionMode = "inherited"
        $script:PermissionTemplate = @()
        $script:PermissionCatalog = @()
        $script:PermissionCatalogSessionId = ""
        Update-PermissionEditorState
        Update-DestinationFolderOptions @() "" $false
        $ConnectionDot.Fill = Get-Brush "#AEAEB2"
        $ConnectionStatus.Text = "URL modificato: ripetere la verifica"
        $ConnectionStatus.Foreground = Get-Brush "#6E6E73"
        Update-ConfigurationState
    }
})

$VerifyButton.Add_Click({
    $VerifyButton.IsEnabled = $false
    $ConnectionDot.Fill = Get-Brush "#C77D00"
    $ConnectionStatus.Text = "Verifica in corso..."
    $ConnectionStatus.Foreground = Get-Brush "#C77D00"
    Add-Activity "Avvio verifica pubblica dell'istanza Passbolt."
    Update-Ui
    try {
        $Url = $PassboltUrl.Text.Trim()
        $Result = Invoke-PythonJson $ProbeScript @("--base-url", $Url, "--discover-fingerprint", "--json")
        $DetectedValue = ([string]$Result.fingerprint).Trim().ToUpperInvariant()
        if ($DetectedValue -notmatch '^[0-9A-F]{40}$') {
            throw "La fingerprint rilevata dal server non e' valida."
        }
        $DetectedFingerprint.Text = $DetectedValue
        $ConfirmationMessage = "Fingerprint OpenPGP rilevata:`n`n$DetectedValue`n`nIl valore e' stato fornito dall'istanza appena contattata. Il rilevamento automatico non dimostra da solo l'identita' del server. Alla prima connessione, confrontarlo con l'amministratore tramite un canale indipendente.`n`nConfermare questa fingerprint per la sessione corrente?"
        $Confirmation = [System.Windows.MessageBox]::Show($ConfirmationMessage, "Conferma fingerprint Passbolt", "YesNo", "Warning")
        if ([string]$Confirmation -ne "Yes") {
            if (Test-ImportSessionActive) {
                Stop-ImportSession "Sessione chiusa perche' la fingerprint Passbolt rilevata non e' stata confermata." $false
            }
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
        $ConnectionStatus.Text = "Connesso - fingerprint confermata: $DetectedValue"
        $ConnectionStatus.Foreground = Get-Brush "#248A3D"
        Add-Activity "Passbolt raggiungibile; healthcheck verificato e fingerprint rilevata confermata dall'utente."
    } catch {
        $FailureMessage = [string]$_.Exception.Message
        if (Test-ImportSessionActive) {
            Stop-ImportSession "Sessione chiusa perche' la verifica pubblica di Passbolt non e' riuscita." $false
        }
        $script:ConnectionVerified = $false
        $script:VerifiedUrl = ""
        $script:VerifiedFingerprint = ""
        $DetectedFingerprint.Text = "Non disponibile"
        Reset-ImportPlan "Verifica pubblica non riuscita. Ripetere connessione e dry-run."
        $ConnectionDot.Fill = Get-Brush "#D70015"
        $ConnectionStatus.Text = "Verifica non riuscita"
        $ConnectionStatus.Foreground = Get-Brush "#D70015"
        Add-Activity "Verifica Passbolt non riuscita: $FailureMessage"
        [System.Windows.MessageBox]::Show($FailureMessage, "Connessione non riuscita", "OK", "Error") | Out-Null
    } finally {
        $VerifyButton.IsEnabled = $true
        Update-ConfigurationState
        Update-ImportSessionState
    }
})

$ClientFolder.Add_TextChanged({
    Update-ConfigurationState
    if ($script:InventoryFolder -and $ClientFolder.Text.Trim() -ne $script:InventoryFolder) {
        if (Test-ImportSessionActive) {
            Stop-ImportSession "Sessione chiusa perche' la cartella clienti e' stata modificata." $false
        }
        $script:InventoryResult = $null
        $script:AllInventoryRows = @()
        $script:ReviewResult = $null
        $script:AllReviewRows = @()
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
    if (-not ($script:ConnectionVerified -and (Test-SelectedFolder))) {
        [System.Windows.MessageBox]::Show("Completare la verifica della connessione e selezionare una cartella valida.", "Configurazione incompleta", "OK", "Warning") | Out-Null
        return
    }
    Show-Page "Inventory"
    if ($null -eq $script:InventoryResult -or $script:InventoryFolder -ne $ClientFolder.Text.Trim()) {
        Invoke-Inventory
    } else {
        Apply-InventoryFilters
    }
})

$BackButton.Add_Click({ Show-Page "Configuration"; Update-ConfigurationState })
$StepConfiguration.Add_MouseLeftButtonUp({ Show-Page "Configuration"; Update-ConfigurationState })
$StepInventory.Add_MouseLeftButtonUp({
    if ($script:ConnectionVerified -and (Test-SelectedFolder)) {
        Show-Page "Inventory"
        if ($null -eq $script:InventoryResult -or $script:InventoryFolder -ne $ClientFolder.Text.Trim()) { Invoke-Inventory }
    }
})
$StepReview.Add_MouseLeftButtonUp({
    if ($null -ne $script:ReviewResult) { Show-Page "Review" }
})
$StepImport.Add_MouseLeftButtonUp({
    if ($script:ImportCandidates.Count -gt 0) { Show-Page "Import" }
})
$RefreshButton.Add_Click({ Invoke-Inventory })
$ClientFilter.Add_SelectionChanged({ Apply-InventoryFilters })
$FormatFilter.Add_SelectionChanged({ Apply-InventoryFilters })
$SearchBox.Add_TextChanged({ Apply-InventoryFilters })
$FilesGrid.Add_SelectionChanged({ Update-ReviewSelectionState })
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
$ImportModeTabs.Add_SelectionChanged({
    param($Sender, $EventArgs)
    if ($EventArgs.OriginalSource -ne $ImportModeTabs) { return }
    if ($ImportModeTabs.SelectedIndex -eq 1 -and $script:RecoveryBatches.Count -eq 0 -and $null -eq $script:RecoveryPlan) {
        Refresh-RecoveryBatches -Quiet
    }
    if ($ImportModeTabs.SelectedIndex -eq 2) { Update-AclViewerState }
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
$ResourceFormat.Add_SelectionChanged({
    if ($null -ne $script:ImportPlan) {
        Reset-ImportPlan "Il formato risorsa e' cambiato. Ripetere il dry-run."
        Add-Activity "Formato risorsa modificato; il piano precedente e' stato invalidato."
    }
})
$FolderFormat.Add_SelectionChanged({
    if ($null -ne $script:ImportPlan) {
        Reset-ImportPlan "Il formato cartelle e' cambiato. Ripetere il dry-run."
        Add-Activity "Formato cartelle modificato; il piano precedente e' stato invalidato."
    }
})
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
$ConfigureClientMappingsButton.Add_Click({ Show-ClientDestinationMappingDialog })
$ConfigurePermissionsButton.Add_Click({ Show-PermissionEditor })
$ImportConfirmation.Add_TextChanged({ Update-ExecuteImportState })
$ImportSessionButton.Add_Click({
    if (Test-ImportSessionActive) {
        Stop-ImportSession "Sessione autenticata chiusa dall'utente." $true
    } elseif ($null -ne $script:ImportSessionProcess -or $script:ImportSessionId) {
        Stop-ImportSession "La sessione locale non era piu disponibile ed e' stata ripulita. Avviarne una nuova." $true
    } else {
        Open-ImportSession
    }
})
$DryRunButton.Add_Click({ Invoke-ImportReadiness })
$ExecuteImportButton.Add_Click({ Invoke-ConfirmedImport })

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
            $ExportButton.IsEnabled = $false
            Add-Activity "Esportazione CSV in corso."
            Update-Ui
            $ExportResult = Invoke-PythonJson $InventoryScript @("--inventory", $script:InventoryFolder, "--csv", $Dialog.FileName, "--json")
            Add-Activity "Report CSV esportato: $($ExportResult.csv_path)"
            [System.Windows.MessageBox]::Show("Inventario esportato correttamente in:`n$($ExportResult.csv_path)", "Esportazione completata", "OK", "Information") | Out-Null
        }
    } catch {
        Add-Activity "Esportazione non riuscita: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Esportazione non riuscita", "OK", "Error") | Out-Null
    } finally {
        $Dialog.Dispose()
        if ($null -ne $script:InventoryResult) { $ExportButton.IsEnabled = $true }
    }
})

$script:ImportSessionTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:ImportSessionTimer.Interval = [TimeSpan]::FromMinutes(1)
$script:ImportSessionTimer.Add_Tick({
    if (($null -ne $script:ImportSessionProcess -or $script:ImportSessionId) -and -not (Test-ImportSessionActive)) {
        Stop-ImportSession "La sessione locale si e' chiusa inaspettatamente ed e' stata ripulita." $true
    } elseif ((Test-ImportSessionActive) -and $script:ImportSessionLastActivityUtc -ne [DateTime]::MinValue) {
        $IdleMinutes = ([DateTime]::UtcNow - $script:ImportSessionLastActivityUtc).TotalMinutes
        if ($IdleMinutes -ge $script:ImportSessionIdleTimeoutMinutes) {
            Stop-ImportSession "Sessione autenticata chiusa automaticamente dopo $($script:ImportSessionIdleTimeoutMinutes) minuti di inattivita'." $true
        }
    }
})
$script:ImportSessionTimer.Start()

$Window.Add_Closing({
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
    if ($null -ne $script:ImportSessionTimer) { $script:ImportSessionTimer.Stop() }
    Stop-ImportSession "" $false
})

Update-DestinationControlState
Update-ImportSessionState
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
    $PreviewRoot = [System.Windows.FrameworkElement]$Window.Content
    $PreviewRoot.Measure([System.Windows.Size]::new($PreviewWidth, $PreviewHeight))
    $PreviewRoot.Arrange([System.Windows.Rect]::new(0, 0, $PreviewWidth, $PreviewHeight))
    $PreviewRoot.UpdateLayout()
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
        version = "0.21.0"
        preview = $PreviewFullPath
        page = $RenderPreviewPage
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
        }
        status = "OK"
    } | ConvertTo-Json
    $Window.Close()
    exit 0
}

if ($SelfTest) {
    $CompatibilityList = New-Object System.Collections.Generic.List[object]
    $CompatibilityList.Add([pscustomobject]@{ value = 1 })
    $CompatibilityArray = $CompatibilityList.ToArray()
    if ($CompatibilityArray.Count -ne 1) {
        throw "Verifica compatibilit$([char]0x00E0) collezioni Windows PowerShell non riuscita."
    }
    if (
        $Window.Title -notmatch "v0\.21\.0" -or
        $Window.MinWidth -lt 1160 -or
        $Window.MinHeight -lt 740 -or
        [string]$Window.FontFamily -notmatch "Segoe UI Variable" -or
        $VerifyButton.MinHeight -lt 40 -or
        $StepConfiguration.CornerRadius.TopLeft -lt 10 -or
        $FilesGrid.RowHeight -lt 40 -or
        $FilesGrid.Columns[1].MinWidth -lt 300 -or
        $null -eq $ClientFolder.Template -or
        $null -eq $DestinationMode.Template -or
        $null -eq $ReviewPasswordToggle.Template -or
        $null -eq $ImportModeTabs.Template
    ) {
        throw "Il design system moderno non rispetta il contratto visivo WPF."
    }
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
    } finally {
        Stop-ImportSession "" $false
        if (Test-Path -LiteralPath $SessionProbePath -PathType Leaf) {
            Remove-Item -LiteralPath $SessionProbePath -Force
        }
    }
    $ReviewBackendTest = Invoke-PythonJson $ReviewScript @("--self-test")
    if ($ReviewBackendTest.secrets_serialized -or -not $ReviewBackendTest.excel_password_prompt_supported -or -not $ReviewBackendTest.unlimited_file_selection -or -not $ReviewBackendTest.unlimited_candidate_collection -or -not $ReviewBackendTest.single_pass_field_detection) {
        throw "Il backend di revisione non rispetta il contratto di mascheramento."
    }
    $ImportBackendTest = Invoke-PythonJson $ImportScript @("--self-test")
    if (-not $ImportBackendTest.ok -or $ImportBackendTest.result.secrets_serialized -or -not $ImportBackendTest.result.unlimited_candidate_selection -or -not $ImportBackendTest.result.indexed_candidate_revalidation -or -not $ImportBackendTest.result.early_parser_stop -or -not $ImportBackendTest.result.persistent_session_protocol -or -not $ImportBackendTest.result.reconciliation_progress_protocol -or -not $ImportBackendTest.result.authenticated_recovery_protocol -or -not $ImportBackendTest.result.recovery_management_protocol -or -not $ImportBackendTest.result.recoverable_archive_protocol -or -not $ImportBackendTest.result.explicit_reveal_supported -or -not $ImportBackendTest.result.protected_excel_integrity_supported -or -not $ImportBackendTest.result.permission_editor_protocol -or -not $ImportBackendTest.result.existing_acl_viewer_protocol -or -not $ImportBackendTest.result.existing_acl_dry_run_protocol -or -not $ImportBackendTest.result.acl_journal_management_protocol) {
        throw "Il backend di importazione non rispetta il contratto di sicurezza."
    }
    $CryptoBackendTest = Invoke-SecureJsonProcess $NodeExecutable @($CryptoScript) ([pscustomobject]@{ command = "self-test" }) 120000
    if (-not $CryptoBackendTest.ok -or $CryptoBackendTest.result.secrets_serialized -or -not $CryptoBackendTest.result.utf8_bom_input -or -not $CryptoBackendTest.result.unlimited_candidate_selection -or -not $CryptoBackendTest.result.indexed_large_batch_planning -or -not $CryptoBackendTest.result.persistent_session_protocol -or -not $CryptoBackendTest.result.reconciliation_progress_protocol -or -not $CryptoBackendTest.result.authenticated_recovery_protocol -or -not $CryptoBackendTest.result.permission_editor_protocol -or -not $CryptoBackendTest.result.existing_acl_viewer_protocol -or -not $CryptoBackendTest.result.existing_acl_dry_run_protocol -or -not $CryptoBackendTest.result.official_wrapped_gpgauth_payload_contract -or -not $CryptoBackendTest.result.official_minimal_totp_payload_contract) {
        throw "Il bridge OpenPGP locale non ha superato il test di sicurezza."
    }
    $IntegrationMatrixTest = Invoke-PythonJson $IntegrationMatrixScript @("self-test")
    if (-not $IntegrationMatrixTest.ok -or $IntegrationMatrixTest.result.secrets_serialized -or -not $IntegrationMatrixTest.result.read_only_automation -or -not $IntegrationMatrixTest.result.ci_real_instance_guard -or -not $IntegrationMatrixTest.result.report_digest_valid -or -not $IntegrationMatrixTest.result.safe_failure_projection -or $IntegrationMatrixTest.result.automated_scenario_count -ne 7 -or $IntegrationMatrixTest.result.manual_scenario_count -ne 9) {
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
    if ([string]$ImportSessionButton.Content -ne "Avvia sessione" -or $script:ImportSessionIdleTimeoutMinutes -ne 30) {
        throw "I controlli UI della sessione autenticata non sono nello stato previsto."
    }
    if ($ImportModeTabs.Items.Count -ne 3 -or $RecoveryConfirmation.IsEnabled -or $VerifyRecoveryButton.IsEnabled -or $ExecuteRecoveryButton.IsEnabled -or (Get-RecoveryStatusLabel "recovery_required") -ne "Recuperabile") {
        throw "I controlli UI del recupero guidato non sono nello stato fail-closed previsto."
    }
    if ($null -ne $Window.FindName("ServerFingerprint") -or [string]$DetectedFingerprint.Text -ne "Non ancora rilevata") {
        throw "La configurazione deve rilevare la fingerprint senza richiedere un inserimento manuale."
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
    if ($null -eq $ExcelPasswordDialogProbe -or $ExcelPasswordDialogProbe.PasswordBox.MaxLength -ne 1024 -or $ExcelPasswordDialogProbe.PasswordText.Visibility -ne "Collapsed") {
        throw "La richiesta protetta della password Excel non puo essere costruita nello stato previsto."
    }
    $ExcelPasswordDialogProbe.Window.Close()
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
    }
    $ReviewEditorProbe = Show-ReviewCandidateEditor $ReviewEditorRowProbe -BuildOnly
    if ($null -eq $ReviewEditorProbe -or $ReviewEditorProbe.Editors.Count -ne 5) {
        throw "L'editor dei candidati non espone i cinque campi previsti."
    }
    $ReviewEditorProbe.Window.Close()
    [pscustomobject]@{
        app = "Passbolt Migration Assistant"
        version = "0.21.0"
        ui = "WPF"
        phases = 4
        controls = 109
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
        protected_excel_password_prompt = "OK"
        persistent_import_session = "OK"
        reconciliation_progress_protocol = "OK"
        authenticated_recovery_protocol = "OK"
        guided_recovery_ui = "OK"
        recoverable_journal_archive = "OK"
        mfa_reused_without_reprompt = "OK"
        automatic_fingerprint_confirmation = "OK"
        safe_login_diagnostics = "OK"
        integration_matrix_backend = "OK"
        unlimited_file_and_candidate_selection = "OK"
        optimized_large_batch_processing = "OK"
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
